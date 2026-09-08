require "http/client"
require "uri"
require "compress/gzip"

module X5ch
  module FivechBrowser
    # Fetch関連のエラー(Go版の `fmt.Errorf` 相当)
    class FetchError < Exception
    end

    # NetworkFetchError はネットワークレベルの失敗(タイムアウト・接続エラー)を表す、FetchErrorの部分集合。
    # Go版が `errors.As(err, &netErr)` (net.Error) でネットワークエラーとHTTPステータスエラー
    # (4xx/5xx、こちらはリトライ対象外)を区別しているのに対応するため、区別できるサブタイプとして追加した。
    # transfer::Worker のリトライ分類で使う。
    class NetworkFetchError < FetchError
    end

    # Fetcher は5chへのHTTPアクセスを担当する(Go版 Fetcher 相当)
    class Fetcher
      MAX_REDIRECTS   =  5
      REQUEST_TIMEOUT = 30.seconds

      def initialize(@user_agent : String)
      end

      # URLを取得し、本文(生バイト列・エンコーディング変換なし)と最終URLを返す。
      #
      # オリジナルRuby版(fetch_with_redirect)は `Accept-Encoding: gzip` を明示的に
      # 送り、`Content-Encoding: gzip` が返れば `Zlib::GzipReader` で手動展開している。
      # Go版はこれを `net/http` のTransportが暗黙にやってくれていた(Accept-Encoding
      # ヘッダーを自分でセットしなければ自動でgzip要求+自動展開される)。
      # Crystalの HTTP::Client は完全に自動ではないため、Ruby版と同じ方式
      # (明示的に要求し、Content-Encodingを見て手動展開)を踏襲する。
      #
      # また、Crystalの HTTP::Client は
      #   1) リダイレクトを自動フォローしない
      #   2) レスポンスボディをUTF-8前提でString化する(`resp.body`)ため、
      #      Shift_JIS等の非UTF-8ページは黙って壊れる
      # という2点への対処も必要。
      # そのため (1) は自前でリダイレクトループを回し、
      # (2) はブロック形式の `body_io.getb_to_end` で生バイトのまま取得する。
      def fetch(url : String) : {Bytes, String}
        current_url = url

        MAX_REDIRECTS.times do |i|
          uri = URI.parse(current_url)
          raise FetchError.new("不正なURL: #{current_url}") unless uri.host

          body_bytes = nil.as(Bytes?)
          final_url = current_url
          redirect_to = nil.as(String?)
          error_msg = nil.as(String?)

          client = HTTP::Client.new(uri)
          client.connect_timeout = REQUEST_TIMEOUT
          client.read_timeout = REQUEST_TIMEOUT

          headers = HTTP::Headers{
            "User-Agent"      => @user_agent,
            "Accept-Encoding" => "gzip",
          }

          begin
            client.get(uri.request_target, headers: headers) do |resp|
              case resp.status_code
              when 300..399
                loc = resp.headers["Location"]?
                if loc.nil?
                  error_msg = "リダイレクト応答にLocationヘッダーがありません: #{resp.status_code}"
                else
                  redirect_to = uri.resolve(loc).to_s
                end
              when 200..299
                raw = resp.body_io.getb_to_end
                if resp.headers["Content-Encoding"]?.try(&.downcase) == "gzip"
                  body_bytes = Compress::Gzip::Reader.open(IO::Memory.new(raw), &.getb_to_end)
                else
                  body_bytes = raw
                end
              else
                error_msg = "HTTP Error: #{resp.status_code} #{resp.status_message}"
              end
            end
          rescue ex : IO::TimeoutError
            raise NetworkFetchError.new("通信タイムアウト: #{ex.message}")
          rescue ex : Socket::Error
            raise NetworkFetchError.new("通信エラー: #{ex.message}")
          rescue ex : Compress::Gzip::Error
            raise FetchError.new("gzip展開エラー: #{ex.message}")
          ensure
            client.close
          end

          raise FetchError.new(error_msg.not_nil!) if error_msg

          if (r = redirect_to)
            current_url = r
            next
          end

          return {body_bytes.not_nil!, final_url}
        end

        raise FetchError.new("リダイレクト回数が上限(#{MAX_REDIRECTS})に達しました")
      end
    end
  end
end
