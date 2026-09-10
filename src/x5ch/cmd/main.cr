require "./config"
require "./lock"
require "./render"
require "./menus"
require "./content"
require "./search_read_cmd"
require "./export_cmd"
require "../history/manager"
require "../discord/manager"
require "../transfer/worker"
require "../selector/selector"
require "../terminal/terminal"

module X5ch
  module Cmd
    # メインメニューの1項目。「★最近読んだスレッド」特別枠と通常カテゴリを区別する。
    struct MenuEntry
      property is_recent : Bool
      property category : X5ch::FivechBrowser::Category?

      def initialize(@is_recent : Bool = false, @category : X5ch::FivechBrowser::Category? = nil)
      end
    end

    class InterruptedFlow < Exception
    end

    def self.main : Nil
      args = ARGV
      if args.size > 0
        case args[0]
        when "export"
          run_export_command(args[1..])
          return
        when "search"
          run_search_command(args[1..])
          return
        when "read"
          run_read_command(args[1..])
          return
        end
        # export-batch はこのCrystal移植の対象範囲外(README記載の通り未実装のまま)。
      end

      cfg = load_config

      lock_file =
        begin
          acquire_lock_with_handoff(cfg.lock_file, cfg.pid_file)
        rescue ex : LockError
          puts "ロック取得エラー: #{ex.message}"
          exit(1)
        end

      write_pid(cfg.pid_file)

      hist =
        begin
          X5ch::History::Manager.new(cfg.history_file)
        rescue ex
          puts "履歴読み込みエラー: #{ex.message}"
          exit(1)
        end

      browser = X5ch::FivechBrowser::Browser.new(cfg.user_agent, hist, cfg.cache_expiration)
      discord_mgr = X5ch::Discord::Manager.new(cfg.discord_bot_token, cfg.discord_channel_id)
      worker = X5ch::Transfer::Worker.new(browser, discord_mgr, hist, cfg.queue_file)

      output = STDOUT
      fd = STDIN.fd
      # プロセス全体を通じて1つだけ生成し、全画面(Selector.run/Pager#start/wait_for_key)で
      # 使い回す共有KeyReader。画面遷移のたびに専用の読み取りFiberを作ると、
      # 前の画面のFiberが次の画面の入力を横取りする実バグがあったため
      # (詳細は KeyReader のコメントを参照)、ここで一度だけ生成して使い回す。
      reader = X5ch::Terminal::KeyReader.new(STDIN)

      # rawモード中(selector/pager画面)のCtrl+Cはバイト0x03として各所で検知され
      # Action::Interrupt/InterruptedFlow として伝播する。rawモードを抜けている間
      # (メニュー間のネットワーク取得中)はOSのSIGINT/SIGTERMとして届くため、ここでも捕捉する。
      # Process.on_interrupt はCrystal 1.12以降で非推奨(on_terminateを使うよう指示される)。
      # on_terminate は Process::ExitReason を受け取るが、割り込み理由に関わらず
      # 同じ後始末を行えばよいため、ここでは引数を使わない。
      Process.on_terminate { |_reason| cleanup_and_exit(worker, cfg.pid_file, lock_file) }
      Signal::TERM.trap { cleanup_and_exit(worker, cfg.pid_file, lock_file) }

      begin
        run_menu_loop(browser, hist, worker, discord_mgr, reader, output, fd)
      rescue InterruptedFlow
        cleanup_and_exit(worker, cfg.pid_file, lock_file)
        return
      rescue ex
        puts "\r\nエラー: #{ex.message}"
      end

      if worker.busy?
        puts "\r\n\e[33m転送処理が残っています。すべて完了するまで待機します...\e[0m"
      end
      worker.wait_until_done
      print("\e[H\e[2J")

      remove_pid(cfg.pid_file)
      lock_file.close
    end

    # Ctrl+C(SIGINT/SIGTERM含む)を受けた際、待機列を保存してから即座に終了する。
    def self.cleanup_and_exit(worker : Transfer::Worker, pid_file : String, lock_file : File) : Nil
      puts "\r\n\e[31m保存して終了します。\e[0m"
      worker.kill
      worker.wait_until_stopped
      remove_pid(pid_file)
      lock_file.close
      exit(0)
    end

    # メインメニュー(カテゴリ一覧+最近読んだスレッド)のループ。
    def self.run_menu_loop(browser : X5ch::FivechBrowser::Browser, hist : X5ch::History::Manager, worker : Transfer::Worker, discord_mgr : X5ch::Discord::Manager, reader : X5ch::Terminal::KeyReader, output : IO, fd : Int32) : Nil
      last_cat_page = 0

      loop do
        cats =
          begin
            browser.get_menu
          rescue ex
            output.puts "メニュー取得エラー: #{ex.message}"
            sleep 2.seconds
            next
          end

        items = [] of Selector::Item(MenuEntry)
        items << Selector::Item.new(render_recent_entry("★ 最近読んだスレッド"), MenuEntry.new(is_recent: true))
        cats.each do |c|
          has_history = hist.has_history_in_category?(c.boards)
          items << Selector::Item.new(render_category_or_board_item(c.title, has_history), MenuEntry.new(category: c))
        end

        cfg = Selector::Config.new("メインメニュー", items)
        cfg.start_page = last_cat_page
        cfg.status_line = ->{ worker.status_string }
        cfg.search_label = "全スレ検索"
        cfg.on_global_search = ->(keyword : String) { run_global_search(browser, hist, worker, discord_mgr, keyword, reader, output, fd) }
        cfg.on_queue_manage = ->(sio : Selector::TermIO) { manage_queue(sio, worker) }
        cfg.on_history_manage = ->(sio : Selector::TermIO) { manage_history(sio, hist) }
        cfg.help_text = help_text("category")

        cat_result = Selector.run(output, fd, cfg, reader)
        last_cat_page = cat_result.page

        case cat_result.action
        when .quit?
          return
        when .back?
          next
        when .interrupt?
          raise InterruptedFlow.new
        end

        entry = cat_result.value.not_nil!
        if entry.is_recent
          recent = hist.get_recent_threads
          if recent.empty?
            output.puts "履歴がありません"
            sleep 1.seconds
            next
          end
          show_recent_stream(browser, hist, recent, reader, output, fd)
          next
        end

        run_board_loop(browser, hist, worker, discord_mgr, entry.category.not_nil!, reader, output, fd)
      end
    end

    def self.run_board_loop(browser : X5ch::FivechBrowser::Browser, hist : X5ch::History::Manager, worker : Transfer::Worker, discord_mgr : X5ch::Discord::Manager, cat : X5ch::FivechBrowser::Category, reader : X5ch::Terminal::KeyReader, output : IO, fd : Int32) : Nil
      last_board_page = 0

      loop do
        items = cat.boards.map do |b|
          has_history = hist.has_history_in_board?(b.url)
          Selector::Item.new(render_category_or_board_item(b.title, has_history), b)
        end

        cfg = Selector::Config.new(cat.title, items)
        cfg.start_page = last_board_page
        cfg.status_line = ->{ worker.status_string }
        cfg.search_label = "絞り込み"
        cfg.supports_reload = true
        cfg.on_queue_manage = ->(sio : Selector::TermIO) { manage_queue(sio, worker) }
        cfg.help_text = help_text("board")

        board_result = Selector.run(output, fd, cfg, reader)

        case board_result.action
        when .quit?, .back?
          return
        when .interrupt?
          raise InterruptedFlow.new
        when .reload?
          next
        end

        last_board_page = board_result.page
        board = board_result.value.not_nil!

        run_thread_loop(browser, hist, worker, discord_mgr, board, reader, output, fd)
      end
    end

    def self.run_thread_loop(browser : X5ch::FivechBrowser::Browser, hist : X5ch::History::Manager, worker : Transfer::Worker, discord_mgr : X5ch::Discord::Manager, board : X5ch::FivechBrowser::Board, reader : X5ch::Terminal::KeyReader, output : IO, fd : Int32) : Nil
      last_thread_page = 0
      force_reload = false

      loop do
        output.puts "スレッド一覧取得中..."
        threads =
          begin
            t = browser.get_threads(board, force_reload)
            force_reload = false
            t
          rescue ex
            force_reload = false
            output.puts "スレッド一覧取得エラー: #{ex.message}"
            sleep 2.seconds
            return
          end

        items = threads.map do |t|
          state = ThreadItemState.new(t, false)
          Selector::Item.new(render_thread_item(state.thread, state.is_queued), state)
        end

        cfg = Selector::Config.new(board.title, items)
        cfg.start_page = last_thread_page
        cfg.status_line = ->{ worker.status_string }
        cfg.search_label = "絞り込み"
        cfg.supports_reload = true
        cfg.can_enqueue = enqueue_guard(discord_mgr)
        cfg.on_enqueue = enqueue_handler(worker, hist)
        cfg.on_history_delete_item = ->(sio : Selector::TermIO, idx : Int32, item : Selector::Item(ThreadItemState)) {
          delete_history_for_thread(sio, hist, item.value)
        }
        cfg.on_queue_manage = ->(sio : Selector::TermIO) { manage_queue(sio, worker) }
        cfg.help_text = help_text("thread")

        thread_result = Selector.run(output, fd, cfg, reader)
        last_thread_page = thread_result.page

        case thread_result.action
        when .quit?, .back?
          return
        when .interrupt?
          raise InterruptedFlow.new
        when .reload?
          force_reload = true
          next
        end

        t = thread_result.value.not_nil!.thread
        show_thread(browser, hist, t, reader, output, fd)
      end
    end

    # カテゴリ画面からの全板検索('s')。結果一覧を別のSelector.runで表示し、
    # 選択されたスレッドを show_thread で読む、というネストしたループ。
    def self.run_global_search(browser : X5ch::FivechBrowser::Browser, hist : X5ch::History::Manager, worker : Transfer::Worker, discord_mgr : X5ch::Discord::Manager, keyword : String, reader : X5ch::Terminal::KeyReader, output : IO, fd : Int32) : Bool
      results =
        begin
          browser.search_global(keyword)
        rescue ex
          output.puts "検索エラー: #{ex.message}"
          wait_for_key(reader)
          return false
        end

      if results.empty?
        output.puts "見つかりませんでした。"
        wait_for_key(reader)
        return false
      end

      last_page = 0
      loop do
        items = results.map do |t|
          state = ThreadItemState.new(t, false)
          Selector::Item.new(render_thread_item(state.thread, state.is_queued), state)
        end

        cfg = Selector::Config.new("全板検索結果: #{keyword}", items)
        cfg.start_page = last_page
        cfg.status_line = ->{ worker.status_string }
        cfg.search_label = "絞り込み"
        cfg.can_enqueue = enqueue_guard(discord_mgr)
        cfg.on_enqueue = enqueue_handler(worker, hist)
        cfg.on_queue_manage = ->(sio : Selector::TermIO) { manage_queue(sio, worker) }
        cfg.help_text = help_text("thread")

        result = Selector.run(output, fd, cfg, reader)
        last_page = result.page

        case result.action
        when .quit?, .back?
          return false
        when .interrupt?
          return true
        when .selected?
          show_thread(browser, hist, result.value.not_nil!.thread, reader, output, fd)
        end
      end
    end

    # 'm'キー押下時の事前チェック(Discordトークン未設定なら拒否)。
    def self.enqueue_guard(discord_mgr : X5ch::Discord::Manager) : Proc({Bool, String})
      ->{
        if discord_mgr.enabled?
          {true, ""}
        else
          {false, "\e[31m[Error] Discordトークン/チャンネルIDが未設定です\e[0m"}
        end
      }
    end

    # 'm'キーでの実際のキュー追加処理。selectorから渡されるitemを直接使うため、
    # (絞り込み中でも)呼び出し元の配列のインデックスを気にする必要がない。
    def self.enqueue_handler(worker : Transfer::Worker, hist : X5ch::History::Manager) : Proc(Selector::TermIO, Int32, Selector::Item(ThreadItemState), {Selector::Item(ThreadItemState), Bool})
      ->(sio : Selector::TermIO, idx : Int32, item : Selector::Item(ThreadItemState)) {
        state = item.value
        worker.enqueue(Transfer::Task.new(title: state.thread.title, board_url: state.thread.board_url, dat_file: state.thread.dat_file))
        hist.add_new_thread(state.thread.title, state.thread.board_url, state.thread.dat_file)
        state.thread.last_read = 0
        new_state = ThreadItemState.new(state.thread, true)
        sio.println(">> キューに追加: #{state.thread.title}")
        sleep 500.milliseconds
        {Selector::Item.new(render_thread_item(new_state.thread, new_state.is_queued), new_state), true}
      }
    end

    def self.delete_history_for_thread(sio : Selector::TermIO, hist : X5ch::History::Manager, state : ThreadItemState) : {Selector::Item(ThreadItemState), Bool}
      if state.thread.last_read > 0
        if hist.delete_thread(state.thread.board_url, state.thread.dat_file)
          state.thread.last_read = 0
          state = ThreadItemState.new(state.thread, false)
          sio.println(">> 履歴を削除しました: #{state.thread.title}")
          sleep 1.seconds
        else
          sio.println("削除に失敗しました")
          sleep 1.seconds
        end
      else
        sio.println("履歴がない(未読の)スレッドです")
        sleep 500.milliseconds
      end
      {Selector::Item.new(render_thread_item(state.thread, state.is_queued), state), true}
    end
  end
end

X5ch::Cmd.main