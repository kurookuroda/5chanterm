require "json"
require "../fivechbrowser/interfaces"
require "../fivechbrowser/browser"
require "./config"

module X5ch
  module Cmd
    # NullHistory は永続化を一切行わないダミーのHistoryStore実装。
    # search/read/export のような使い捨てCLIコマンドでは閲覧履歴を参照・更新する必要が無いが、
    # SearchGlobal や GetThreadData(内部でDetectAndAddNextThreadも動く)は
    # HistoryStore を実際に呼び出すため、必ずこのno-op実装を使う。
    class NullHistory
      include X5ch::FivechBrowser::HistoryStore

      def get_last_read(board_url : String, dat_file : String) : Int32
        0
      end

      def exists?(board_url : String, dat_file : String) : Bool
        false
      end

      def add_new_thread(title : String, board_url : String, dat_file : String) : Nil
      end
    end

    class JsonSearchResult
      include JSON::Serializable
      property title : String
      property count : Int32
      @[JSON::Field(key: "board_url")]
      property board_url : String
      @[JSON::Field(key: "dat_file")]
      property dat_file : String
      property url : String

      def initialize(@title, @count, @board_url, @dat_file, @url)
      end
    end

    class JsonThread
      include JSON::Serializable
      property title : String
      @[JSON::Field(key: "board_url")]
      property board_url : String
      @[JSON::Field(key: "dat_file")]
      property dat_file : String
      property count : Int32

      def initialize(@title, @board_url, @dat_file, @count)
      end
    end

    class JsonPost
      include JSON::Serializable
      property num : Int32
      property name : String
      property date : String
      property message : String

      def initialize(@num, @name, @date, @message)
      end
    end

    # JsonEnvelope は search/read サブコマンド共通の出力封筒。成功/失敗を明示する。
    class JsonEnvelope
      include JSON::Serializable
      property ok : Bool
      @[JSON::Field(emit_null: false)]
      property error : String?
      @[JSON::Field(key: "error_type", emit_null: false)]
      property error_type : String?
      @[JSON::Field(emit_null: false)]
      property results : Array(JsonSearchResult)?
      @[JSON::Field(emit_null: false)]
      property thread : JsonThread?
      @[JSON::Field(emit_null: false)]
      property posts : Array(JsonPost)?

      def initialize(
        @ok : Bool,
        @error : String? = nil,
        @error_type : String? = nil,
        @results : Array(JsonSearchResult)? = nil,
        @thread : JsonThread? = nil,
        @posts : Array(JsonPost)? = nil,
      )
      end
    end

    # エラーを "thread_gone" / "network" / "other" に分類する。
    def self.classify_error_type(ex : Exception) : String
      return "thread_gone" if ex.is_a?(X5ch::FivechBrowser::ThreadGoneError)
      return "network" if ex.is_a?(X5ch::FivechBrowser::NetworkFetchError)
      "other"
    end

    def self.write_envelope(env : JsonEnvelope, io : IO = STDOUT) : Nil
      io.puts(env.to_pretty_json)
    end

    # `x5ch search <keyword>` を処理する。
    def self.run_search_command(args : Array(String)) : Nil
      if args.empty?
        write_envelope(JsonEnvelope.new(ok: false, error: "使い方: x5ch search <keyword>", error_type: "other"), STDERR)
        exit(1)
      end
      keyword = args[0]

      cfg = load_config
      browser = X5ch::FivechBrowser::Browser.new(cfg.user_agent, NullHistory.new, cfg.cache_expiration)

      results =
        begin
          browser.search_global(keyword)
        rescue ex
          write_envelope(JsonEnvelope.new(ok: false, error: ex.message || "", error_type: classify_error_type(ex)), STDERR)
          exit(1)
        end

      json_results = results.map do |r|
        JsonSearchResult.new(title: r.title, count: r.count, board_url: r.board_url, dat_file: r.dat_file, url: r.url)
      end
      write_envelope(JsonEnvelope.new(ok: true, results: json_results))
    end

    # `x5ch read <board_url> <dat_file>` を処理する。
    def self.run_read_command(args : Array(String)) : Nil
      if args.size < 2
        write_envelope(JsonEnvelope.new(ok: false, error: "使い方: x5ch read <board_url> <dat_file>", error_type: "other"), STDERR)
        exit(1)
      end
      board_url = args[0]
      dat_file = args[1]

      cfg = load_config
      browser = X5ch::FivechBrowser::Browser.new(cfg.user_agent, NullHistory.new, cfg.cache_expiration)

      t = X5ch::FivechBrowser::ThreadInfo.new(dat_file: dat_file, board_url: board_url)
      posts =
        begin
          browser.get_thread_data(t)
        rescue ex
          write_envelope(JsonEnvelope.new(ok: false, error: ex.message || "", error_type: classify_error_type(ex)), STDERR)
          exit(1)
        end

      json_posts = posts.map { |p| JsonPost.new(num: p.num, name: p.name, date: p.date, message: p.message) }

      write_envelope(JsonEnvelope.new(
        ok: true,
        thread: JsonThread.new(title: t.title, board_url: board_url, dat_file: dat_file, count: posts.size),
        posts: json_posts,
      ))
    end
  end
end
