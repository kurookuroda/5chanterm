require "uri"
require "./types"
require "./fetch"
require "./menu"
require "./interfaces"

module X5ch
  module FivechBrowser
    CURRENT_BOARD_URL_PATTERN = /^https?:\/\/([^\/]+)\/([^\/]+)\//
    # Go版の (?is) = 大文字小文字無視 + DOTALL。Crystalでは /mi (mがDOTALL、iが大文字小文字無視) が同義。
    TITLE_TAG_PATTERN    = /<title>(.*?)<\/title>/mi
    TITLE_SUFFIX_PATTERN = /\s*[-|]\s*5ch\.(net|io).*/mi

    # 現スレの900番以降のレスから次スレURLを検出し、未登録なら履歴に追加する。
    def self.detect_and_add_next_thread(fetcher : Fetcher, history : HistoryStore, posts : Array(Post), current : ThreadInfo) : Nil
      candidates = posts.select { |p| p.num >= 900 }
      return if candidates.empty?

      m = CURRENT_BOARD_URL_PATTERN.match(current.board_url)
      return unless m
      server = m[1]
      board = m[2]

      next_thread_pattern = Regex.new(
        "https?://#{Regex.escape(server)}/test/read\\.cgi/#{Regex.escape(board)}/(\\d+)/?"
      )

      candidates.each do |post|
        post.message.scan(next_thread_pattern) do |match|
          dat_key = match[1]
          dat_file = "#{dat_key}.dat"

          next if history.exists?(current.board_url, dat_file)
          next if dat_file == current.dat_file

          title = fetch_thread_title(fetcher, current.board_url, dat_key)
          history.add_new_thread(title, current.board_url, dat_file) unless title.empty?
        end
      end
    end

    def self.fetch_thread_title(fetcher : Fetcher, board_url : String, dat_key : String) : String
      uri =
        begin
          URI.parse(board_url)
        rescue URI::Error
          return ""
        end

      segments = uri.path.split('/').reject(&.empty?)
      return "" if segments.empty?
      board_name = segments.last

      read_url = "#{uri.scheme}://#{uri.authority}/test/read.cgi/#{board_name}/#{dat_key}/"

      body, _ =
        begin
          fetcher.fetch(read_url)
        rescue FetchError
          return ""
        end

      html = decode_to_utf8(body)

      tm = TITLE_TAG_PATTERN.match(html)
      return "" unless tm

      title = tm[1].strip
      title = title.gsub(TITLE_SUFFIX_PATTERN, "")
      title.strip
    end
  end
end
