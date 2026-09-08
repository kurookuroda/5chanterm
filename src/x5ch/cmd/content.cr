require "../fivechbrowser/browser"
require "../history/manager"
require "../pager/pager"

module X5ch
  module Cmd
    # 1スレッドを取得してPager相当で表示し、既読位置を履歴に保存する。
    # Ruby版 FiveChBrowser#show_thread に対応。
    #
    # 注意: Go版は t を値渡し(呼び出し元に影響しないローカルコピー)しているが、
    # Crystal版の ThreadInfo は class(参照型)なので、ここでの t.count=/t.last_read=
    # は呼び出し元が保持する同じインスタンスにも反映される。これは browser.cr の
    # get_thread_data が既に t.url を同様に書き換える設計と一貫している
    # (呼び出し元のスレッド一覧が実態と同期される、という意図せざる利点でもある)。
    def self.show_thread(browser : X5ch::FivechBrowser::Browser, hist : X5ch::History::Manager, t : X5ch::FivechBrowser::ThreadInfo, input : IO, output : IO, fd : Int32) : Nil
      saved = hist.get_last_read(t.board_url, t.dat_file)
      t.last_read = saved if saved > 0

      output.puts("スレッド取得中...")
      output.flush
      posts =
        begin
          browser.get_thread_data(t)
        rescue
          [] of X5ch::FivechBrowser::Post
        end

      if posts.empty?
        output.puts("取得失敗またはdat落ち")
        output.flush
        wait_for_key(input)
        return
      end
      t.count = posts.size

      content = [Pager::ContentItem.new(Pager::ContentType::Header, thread: t)]
      marker_inserted = false
      posts.each do |p|
        if !marker_inserted && p.num > t.last_read
          content << Pager::ContentItem.new(Pager::ContentType::UnreadMarker, thread: t)
          marker_inserted = true
        end
        content << Pager::ContentItem.new(Pager::ContentType::Post, thread: t, post: p)
      end
      unless marker_inserted
        content << Pager::ContentItem.new(Pager::ContentType::UnreadMarker, thread: t)
        content << Pager::ContentItem.new(Pager::ContentType::SystemMsg, thread: t, message: "(新着なし - 最終レスまで既読です)")
      end

      result =
        begin
          Pager::Pager.new(content).start(input, output, fd)
        rescue
          nil
        end

      if result && result.res > 0
        hist.update_history(t, result.res, nil)
        output.print("\r\n履歴を更新しました: #{result.res}\r\n")
        output.flush
        sleep 500.milliseconds
      end
    end

    # 複数スレッドの新着をまとめて表示する。Ruby版 FiveChBrowser#show_recent_stream に対応。
    def self.show_recent_stream(browser : X5ch::FivechBrowser::Browser, hist : X5ch::History::Manager, threads : Array(X5ch::History::RecentThread), input : IO, output : IO, fd : Int32) : Nil
      content = [] of Pager::ContentItem

      threads.each_with_index do |rt, idx|
        th = rt.thread_info
        output.print("\e[2K\r(#{idx + 1}/#{threads.size}) 取得中: #{th.title}")
        output.flush

        posts =
          begin
            browser.get_thread_data(th)
          rescue
            content << Pager::ContentItem.new(Pager::ContentType::Error, thread: th, message: "取得失敗: #{th.title}")
            next
          end
        th.count = posts.size
        last_read = th.last_read

        content << Pager::ContentItem.new(Pager::ContentType::Header, thread: th)

        new_posts = posts.select { |p| p.num > last_read }

        if new_posts.empty? && last_read == 0
          content << Pager::ContentItem.new(Pager::ContentType::UnreadMarker, thread: th)
          posts.each { |p| content << Pager::ContentItem.new(Pager::ContentType::Post, thread: th, post: p) }
        elsif new_posts.empty?
          content << Pager::ContentItem.new(Pager::ContentType::SystemMsg, thread: th, message: "(新着なし)")
        else
          content << Pager::ContentItem.new(Pager::ContentType::UnreadMarker, thread: th) if last_read > 0
          new_posts.each { |p| content << Pager::ContentItem.new(Pager::ContentType::Post, thread: th, post: p) }
        end
        content << Pager::ContentItem.new(Pager::ContentType::Separator, thread: th)
      end

      if content.empty?
        output.print("\r\n表示できる内容がありません")
        output.flush
        sleep 1.seconds
        return
      end

      result =
        begin
          Pager::Pager.new(content).start(input, output, fd)
        rescue
          nil
        end

      if result && (rt = result.thread) && result.res > 0
        hist.update_history(rt, result.res, nil)
        output.print("\r\n履歴を更新しました: #{rt.title} (#{result.res})\r\n")
        output.flush
        sleep 500.milliseconds
      end
    end

    def self.wait_for_key(input : IO) : Nil
      input.read_byte
    end
  end
end
