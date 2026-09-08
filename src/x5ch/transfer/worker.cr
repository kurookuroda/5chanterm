require "json"
require "../fivechbrowser/types"
require "../fivechbrowser/fetch"
require "../fivechbrowser/browser"
require "./interfaces"

module X5ch
  module Transfer
    # Worker はキューに積まれたタスクを順にDiscordへ転送するバックグラウンド処理を担う。
    # Go版の sync.Cond に相当する仕組みがCrystal標準に無いため、
    # 「チャネルをcloseすることで、そのチャネルをreceive待ちしている全fiberを
    #  一斉に起こす」パターン(Go/Crystalでよく使われるcond変数の代替イディオム)で
    # Wait/Signal/Broadcastを再現している。
    # 待機側は毎回 @mutex 保持中に現在のチャネル参照を取得してから解放して待つことで、
    # 「broadcastがちょうど間に挟まって見逃す」古典的なcond変数のレースを避けている
    # (close済みチャネルへのreceiveは即座に例外を返すため、取りこぼしが起きない)。
    class Worker
      def initialize(
        @browser : ThreadDataFetcher,
        @discord : DiscordClient,
        @history : HistoryUpdater,
        @queue_file : String,
        @network_retry_delay : Time::Span = 30.seconds,
        @discord_retry_delay : Time::Span = 10.seconds,
        @message_interval : Time::Span = 1.seconds,
      )
        @mutex = Mutex.new
        @wake_channel = Channel(Nil).new
        @queue = [] of Task
        @working = false
        @suspended = false
        @shutdown = false
        @current_task = nil.as(Task?)
        @current_idx = 0
        @total_msgs = 0
        @last_error = ""
        @done_channel = Channel(Nil).new

        load_queue
        spawn { run }
      end

      private def broadcast_wake : Nil
        old = @wake_channel
        @wake_channel = Channel(Nil).new
        old.close
      end

      private def wait_on(channel : Channel(Nil)) : Nil
        channel.receive
      rescue Channel::ClosedError
      end

      private def load_queue : Nil
        return unless File.exists?(@queue_file)
        body = File.read(@queue_file)
        begin
          @queue = Array(Task).from_json(body)
        rescue JSON::ParseException
        end
      end

      # 呼び出し側が既に @mutex をロックしている前提で呼ぶ。
      private def save_queue_locked : Nil
        File.write(@queue_file, @queue.to_pretty_json)
      rescue
      end

      # タスクをキューに追加し、待機中のワーカーを起こす。
      def enqueue(task : Task) : Nil
        @mutex.synchronize do
          @last_error = ""
          @queue << task
          save_queue_locked
        end
        broadcast_wake
      end

      # キューの指定indexのタスクを削除する。
      def delete_at(index : Int32) : Task?
        @mutex.synchronize do
          return nil if index < 0 || index >= @queue.size
          removed = @queue.delete_at(index)
          save_queue_locked
          removed
        end
      end

      def queue_list : Array(Task)
        @mutex.synchronize { @queue.dup }
      end

      def busy? : Bool
        @mutex.synchronize { !@queue.empty? || @working }
      end

      def remaining_threads : Int32
        @mutex.synchronize { @queue.size }
      end

      def last_error : String
        @mutex.synchronize { @last_error }
      end

      def suspend : Nil
        @mutex.synchronize { @suspended = true }
      end

      def resume : Nil
        @mutex.synchronize { @suspended = false }
        broadcast_wake
      end

      # ワーカーを停止させる。処理中のタスクがあればキューの先頭に戻してから保存する。
      def kill : Nil
        @mutex.synchronize do
          @shutdown = true
          if @working && (t = @current_task)
            @queue.unshift(t)
          end
          save_queue_locked
        end
        broadcast_wake
      end

      # ワーカーfiberが完全に終了した際にcloseされるチャネルを返す(select等での合成用)。
      # 直接 receive するとCrystalの仕様上 Channel::ClosedError が送出される
      # (Goの「close済みチャネルの受信はゼロ値を返す」とは異なる)ため、
      # 単純に完了を待ちたいだけの場合は wait_until_stopped を使うこと。
      def done : Channel(Nil)
        @done_channel
      end

      # ワーカーfiberが完全に終了するまでブロックする。
      def wait_until_stopped : Nil
        @done_channel.receive
      rescue Channel::ClosedError
      end

      # キューが空になり、処理中のタスクも無くなるまでブロックする。
      def wait_until_done : Nil
        loop do
          wake_ch = nil
          @mutex.synchronize do
            wake_ch = @wake_channel unless @queue.empty? && !@working
          end
          ch = wake_ch
          break unless ch
          wait_on(ch)
        end
      end

      # キュー/転送の進捗を表す色付き文字列を返す。Ruby版 status_string に対応。
      def status_string : String
        @mutex.synchronize do
          unless @last_error.empty?
            next " \e[41m[#{@last_error}]\e[0m"
          end

          is_busy = !@queue.empty? || @working
          next "" unless is_busy

          title_info = "準備中"
          if t = @current_task
            title_info = "#{t.title[0, 8]}..."
          end

          progress = ""
          if @working && @total_msgs > 0
            progress = "(#{@current_idx}/#{@total_msgs})"
          end

          queue_info = @queue.empty? ? "" : " [待機スレ:#{@queue.size}]"

          " \e[33m[転送中:#{title_info}#{progress}#{queue_info}]\e[0m"
        end
      end

      private def run : Nil
        loop do
          task = nil.as(Task?)

          loop do
            wake_ch = nil
            @mutex.synchronize do
              should_wait = (@queue.empty? || @suspended) && !@shutdown
              wake_ch = @wake_channel if should_wait
            end
            ch = wake_ch
            break unless ch
            wait_on(ch)
          end

          shutdown_now = false
          @mutex.synchronize do
            if !@shutdown && !@queue.empty?
              t = @queue.shift
              task = t
              @current_task = t
              save_queue_locked
            end
            shutdown_now = @shutdown
          end

          if shutdown_now && task.nil?
            break
          end
          next if task.nil?

          t = task

          @mutex.synchronize do
            @working = true
            @current_idx = 0
            @total_msgs = 0
          end

          begin
            process_mirror(t)
            @mutex.synchronize { @last_error = "" }
          rescue ex
            handle_task_error(t, ex)
          end

          @mutex.synchronize do
            @current_task = nil
            @working = false
          end
          broadcast_wake
        end

        @done_channel.close
      end

      private def process_mirror(task : Task) : Nil
        t = X5ch::FivechBrowser::ThreadInfo.new(
          dat_file: task.dat_file,
          title: task.title,
          board_url: task.board_url,
        )

        posts =
          begin
            @browser.get_thread_data(t)
          rescue ex : X5ch::FivechBrowser::ThreadGoneError
            return # dat落ちは失敗ではなく単に諦める(Ruby版: postsがnilならreturnのみ)
          end
        return if posts.empty?

        discord_thread_id = @history.get_discord_thread_id(task.board_url, task.dat_file)
        if discord_thread_id.nil? || discord_thread_id.empty?
          discord_thread_id = @discord.create_thread(task.title)
          @history.update_history(t, 0, discord_thread_id)
        end

        last_read = @history.get_last_read(task.board_url, task.dat_file)
        new_posts = posts.select { |p| p.num > last_read }
        return if new_posts.empty?

        @mutex.synchronize { @total_msgs = new_posts.size }

        new_posts.each_with_index do |post, idx|
          shutdown_now = @mutex.synchronize { @shutdown }
          break if shutdown_now

          @mutex.synchronize { @current_idx = idx + 1 }

          @discord.send_message(discord_thread_id, post)
          @history.update_history(t, post.num, discord_thread_id)

          sleep @message_interval
        end
      end

      private def handle_task_error(task : Task, ex : Exception) : Nil
        case ex
        when X5ch::FivechBrowser::NetworkFetchError
          set_last_error("Network Error! Retry later...")
          sleep @network_retry_delay
          requeue(task)
        when DiscordAPIError
          set_last_error(truncate(ex.message || "", 20))
          sleep @discord_retry_delay
          requeue(task)
        else
          set_last_error(truncate(ex.message || "", 20))
          # Ruby版同様、その他のエラーはログのみでrequeueしない
        end
      end

      private def set_last_error(msg : String) : Nil
        @mutex.synchronize { @last_error = msg }
      end

      private def requeue(task : Task) : Nil
        @mutex.synchronize do
          @queue << task
          save_queue_locked
        end
        broadcast_wake
      end

      private def truncate(s : String, n : Int32) : String
        s.size <= n ? s : s[0, n]
      end
    end
  end
end
