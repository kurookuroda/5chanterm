require "uri"
require "./types"
require "./fetch"
require "./menu"
require "./threads"
require "./search"
require "./nextthread"
require "./parse"
require "./export"
require "./interfaces"
require "../transfer/interfaces"

module X5ch
  module FivechBrowser
    class BrowserError < Exception
    end

    THREAD_GONE_MESSAGE = "スレッドはdat落ちしています"

    class ThreadGoneError < BrowserError
      def initialize
        super(THREAD_GONE_MESSAGE)
      end
    end

    private record CachedThreads, data : Array(ThreadInfo), time : Time

    # Browser は各モジュール関数(GetMenu/GetThreads/SearchGlobal/ParsePosts等)をまとめ、
    # メニュー・スレ一覧のキャッシュを保持する調整役。Go版の *Browser に対応。
    #
    # スレッド安全性についてはGo版の sync.Mutex を Crystal の Mutex にそのまま対応させている。
    # Crystalはデフォルトでシングルスレッド実行(ファイバーによる協調的並行性)だが、
    # 将来マルチスレッド化(-Dpreview_mt等)されても安全なように、Go版と同じ排他制御を保持する。
    class Browser
      include X5ch::Transfer::ThreadDataFetcher
      def initialize(user_agent : String, @history : HistoryStore, @cache_expire : Time::Span)
        @fetcher = Fetcher.new(user_agent)
        @menu_mutex = Mutex.new
        @menu_cache = nil.as(Array(Category)?)
        @thread_mutex = Mutex.new
        @thread_cache = {} of String => CachedThreads
      end

      def get_menu : Array(Category)
        @menu_mutex.synchronize do
          if cached = @menu_cache
            return cached
          end
          cats = X5ch::FivechBrowser.get_menu(@fetcher)
          @menu_cache = cats
          cats
        end
      end

      # force_reload=false の場合、cache_expire以内ならキャッシュを返す。
      # 取得に失敗した場合、期限切れであっても古いキャッシュがあればそれにフォールバックする。
      def get_threads(board : Board, force_reload : Bool = false) : Array(ThreadInfo)
        unless force_reload
          @thread_mutex.synchronize do
            if cached = @thread_cache[board.url]?
              return cached.data if Time.utc - cached.time < @cache_expire
            end
          end
        end

        stale = @thread_mutex.synchronize { @thread_cache[board.url]? }

        threads =
          begin
            X5ch::FivechBrowser.get_threads(@fetcher, @history, board)
          rescue ex : ThreadsError
            return stale.data if stale
            raise ex
          end

        @thread_mutex.synchronize do
          @thread_cache[board.url] = CachedThreads.new(data: threads, time: Time.utc)
        end

        threads
      end

      def search_global(keyword : String) : Array(ThreadInfo)
        X5ch::FivechBrowser.search_global(@fetcher, @history, keyword)
      end

      # 指定スレッドをアーカイブ用の完全なJSON構造で取得する。
      # since_num が0より大きい場合、その番号以下のレスは posts から除外する
      # (thread.post_count は除外前の総レス数のまま)。
      def export_thread_data(board_url : String, dat_file : String, since_num : Int32 = 0) : ExportResult
        read_url = X5ch::FivechBrowser.build_read_url(board_url, dat_file)

        body, final_url =
          begin
            @fetcher.fetch(read_url)
          rescue ex : FetchError
            raise BrowserError.new("スレッド取得に失敗しました: #{ex.message}")
          end

        html = X5ch::FivechBrowser.decode_to_utf8(body)

        raise ThreadGoneError.new if html.includes?("dat落ち")

        uri =
          begin
            URI.parse(board_url)
          rescue ex : URI::Error
            raise BrowserError.new("board_urlの解析に失敗: #{ex.message}")
          end
        dat_num = dat_file.sub(/\.dat$/, "")
        thread_external_id = "5ch:#{uri.authority}#{uri.path}#{dat_num}"

        all_posts = X5ch::FivechBrowser.parse_posts_for_export(html, thread_external_id)

        title = ""
        if m = TITLE_TAG_PATTERN.match(html)
          title = m[1].strip.gsub(TITLE_SUFFIX_PATTERN, "").strip
        end

        posts = since_num > 0 ? all_posts.select { |p| p.num > since_num } : all_posts

        ExportResult.new(
          source: ExportSource.new(
            provider: "5ch",
            board_url: board_url,
            dat_file: dat_file,
            thread_url: final_url,
            scraped_at: Time.utc.to_rfc3339,
          ),
          thread: ExportThread.new(
            external_id: thread_external_id,
            title: title,
            board_name: (bn = X5ch::FivechBrowser.extract_board_name(html)).empty? ? nil : bn,
            created_at: (ca = X5ch::FivechBrowser.dat_timestamp_to_rfc3339(dat_file)).empty? ? nil : ca,
            post_count: all_posts.size,
          ),
          posts: posts,
        )
      end

      # 指定スレッドの全レスを取得する。取得後、900番以降のレスから次スレを検出して履歴に追加する。
      # `t.url` は最終URL(リダイレクト解決後)で書き換えられる(Go版の `t *ThreadInfo` と同様、
      # ThreadInfoはclassなので呼び出し元にも反映される)。
      def get_thread_data(t : ThreadInfo) : Array(Post)
        read_url = X5ch::FivechBrowser.build_read_url(t.board_url, t.dat_file)

        body, final_url =
          begin
            @fetcher.fetch(read_url)
          rescue ex : FetchError
            raise BrowserError.new("スレッド取得に失敗しました: #{ex.message}")
          end

        html = X5ch::FivechBrowser.decode_to_utf8(body)

        raise ThreadGoneError.new if html.includes?("dat落ち")

        posts = X5ch::FivechBrowser.parse_posts(html)
        t.url = final_url

        X5ch::FivechBrowser.detect_and_add_next_thread(@fetcher, @history, posts, t)

        posts
      end
    end

    # board_url + dat_file から read.cgi の完全URLを組み立てる。
    # Browser#get_thread_data と(後述の)ExportThreadData の両方から共有される。
    def self.build_read_url(board_url : String, dat_file : String) : String
      uri =
        begin
          URI.parse(board_url)
        rescue ex : URI::Error
          raise BrowserError.new("board_urlの解析に失敗: #{ex.message}")
        end

      segments = uri.path.split('/').reject(&.empty?)
      raise BrowserError.new("board_urlから板名を特定できません: #{board_url}") if segments.empty?
      board_name = segments.last

      dat_num = dat_file.sub(/\.dat$/, "")
      raise BrowserError.new("不正なdat_file: #{dat_file}") unless dat_num.to_i64?

      "#{uri.scheme}://#{uri.authority}/test/read.cgi/#{board_name}/#{dat_num}/"
    end
  end
end
