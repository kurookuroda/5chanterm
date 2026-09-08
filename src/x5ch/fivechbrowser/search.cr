require "uri"
require "./types"
require "./fetch"
require "./interfaces"
require "./parse" # HTML_TAG_PATTERN を再利用する (Go版では search.go 側の定義を parse.go/export.go が再利用する配置だったが、機能的には同じ)

module X5ch
  module FivechBrowser
    class SearchError < Exception
    end

    SEARCH_BASE_URL = "https://ff5ch.syoboi.jp/?q="

    SEARCH_RESULT_PATTERN = /<a\s+[^>]*href="(https?:\/\/[^.]+\.5ch\.(?:net|io)\/test\/read\.cgi\/[^\/]+\/\d+\/?)"[^>]*>(.+?)<\/a>/i
    THREAD_URL_PATTERN    = /https?:\/\/([^.]+)\.5ch\.(?:net|io)\/test\/read\.cgi\/([^\/]+)\/(\d+)\/?/
    TITLE_COUNT_PATTERN   = /^(.*)\((\d+)\)$/

    # ff5ch.syoboi.jp (5ch全板横断検索サイト) は5ch.io自体と異なりUTF-8で応答するため、
    # CP932デコード(decode_to_utf8)ではなくUTF-8としての妥当性チェックのみ行う。
    # 不正なバイト列が混ざっていた場合は置換文字(U+FFFD)に差し替えて処理を続行する
    # (Go版の strings.ToValidUTF8、Ruby原典の String#scrub と同じ役割)。
    def self.to_valid_utf8(body : Bytes) : String
      s = String.new(body)
      s.valid_encoding? ? s : s.scrub
    end

    # キーワードでff5ch経由の全板横断検索を行う。
    def self.search_global(fetcher : Fetcher, history : HistoryStore, keyword : String) : Array(ThreadInfo)
      search_url = SEARCH_BASE_URL + URI.encode_www_form(keyword)

      body, _ =
        begin
          fetcher.fetch(search_url)
        rescue ex : FetchError
          raise SearchError.new("検索エラー: #{ex.message}")
        end

      html = to_valid_utf8(body)

      results = [] of ThreadInfo

      html.scan(SEARCH_RESULT_PATTERN) do |m|
        full_url = m[1]
        raw_title = m[2]

        url_parts = THREAD_URL_PATTERN.match(full_url)
        next unless url_parts

        server = url_parts[1]
        board_name = url_parts[2]
        dat_num = url_parts[3]

        title = raw_title.gsub(HTML_TAG_PATTERN, "").strip
        count = 0
        if cm = TITLE_COUNT_PATTERN.match(title)
          title = cm[1].strip
          count = cm[2].to_i? || 0
        end

        board_url = "https://#{server}.5ch.io/#{board_name}/"
        dat_file = "#{dat_num}.dat"
        last_read = history.get_last_read(board_url, dat_file)

        results << ThreadInfo.new(
          dat_file: dat_file,
          title: title,
          count: count,
          ikioi: 0.0,
          board_url: board_url,
          last_read: last_read,
          url: "https://#{server}.5ch.io/test/read.cgi/#{board_name}/#{dat_num}/",
        )
      end

      results
    end
  end
end
