require "http/client"
require "json"
require "../fivechbrowser/types"
require "../transfer/interfaces"

module X5ch
  module Discord
    # apiBase はDiscord APIのベースURL。テストからローカルサーバーに差し替えられるよう
    # クラス変数にしている(Go版の package変数 + testAPIBaseOverride に対応)。
    @@api_base = "https://discord.com/api/v10"
    @@test_api_base_override = nil.as(String?)

    def self.api_base=(url : String?)
      @@test_api_base_override = url
    end

    def self.current_api_base : String
      @@test_api_base_override || @@api_base
    end

    # Manager はDiscord Botとしてスレッド作成・メッセージ送信を行う。
    # X5ch::Transfer::DiscordClient を実装する。
    class Manager
      include X5ch::Transfer::DiscordClient

      def initialize(@token : String, @channel_id : String)
      end

      def enabled? : Bool
        return false if @token.empty? || @token.includes?("YOUR_BOT_TOKEN")
        return false if @channel_id.empty?
        true
      end

      def create_thread(title : String) : String
        raise X5ch::Transfer::DiscordAPIError.new("Discord機能が無効です(トークン/チャンネルID未設定)") unless enabled?

        safe_title = X5ch::Discord.truncate_runes(title, 95)

        body = {
          "name"                  => safe_title,
          "type"                  => 11,
          "auto_archive_duration" => 1440,
        }.to_json

        url = "#{X5ch::Discord.current_api_base}/channels/#{@channel_id}/threads"

        status, resp_body = do_post(url, body)

        raise X5ch::Transfer::DiscordAPIError.new("#{status} #{resp_body}") unless status == 201

        parsed = JSON.parse(resp_body)
        id = parsed["id"]?.try(&.as_s?)
        raise X5ch::Transfer::DiscordAPIError.new("レスポンス解析エラー: id フィールドがありません") unless id
        id
      end

      def send_message(discord_thread_id : String, post : X5ch::FivechBrowser::Post) : Nil
        return if !enabled? || discord_thread_id.empty?

        header = "**#{post.num}** : #{post.name} : #{post.date}"
        full_content = "#{header}\n#{post.message}"

        if full_content.size <= 2000
          post_content(discord_thread_id, full_content)
          return
        end

        parts = X5ch::Discord.split_by_runes(full_content, 1900)
        parts.each_with_index do |part, i|
          content = part
          content += "\n(続く...)" if i < parts.size - 1
          post_content(discord_thread_id, content)
          sleep 500.milliseconds
        end
      end

      private def post_content(thread_id : String, content : String) : Nil
        body = {"content" => content}.to_json
        url = "#{X5ch::Discord.current_api_base}/channels/#{thread_id}/messages"

        loop do
          status, resp_body = do_post(url, body)

          if status == 429
            sleep parse_retry_after(resp_body)
            next
          end

          if status >= 400
            raise X5ch::Transfer::DiscordAPIError.new("#{status} #{resp_body}")
          end

          return
        end
      end

      private def parse_retry_after(resp_body : String) : Time::Span
        retry_after = 0.0
        begin
          parsed = JSON.parse(resp_body)
          retry_after = parsed["retry_after"]?.try(&.as_f?) || parsed["retry_after"]?.try(&.as_i?).try(&.to_f) || 0.0
        rescue JSON::ParseException
        end
        retry_after <= 0 ? 1.seconds : (retry_after * 1000).milliseconds
      end

      # Discord APIへPOSTし、(ステータスコード, ボディ文字列) を返す。
      private def do_post(url : String, body : String) : {Int32, String}
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 30.seconds

        headers = HTTP::Headers{
          "Authorization" => "Bot #{@token}",
          "Content-Type"  => "application/json",
        }

        resp = client.post(uri.request_target, headers: headers, body: body)
        client.close
        {resp.status_code, resp.body}
      end
    end

    # truncate_runes は文字数(コードポイント数)基準で切り詰める(Goの []rune ベースと同じ)。
    def self.truncate_runes(s : String, n : Int32) : String
      return s if s.size <= n
      "#{s[0, n]}..."
    end

    # split_by_runes は文字数基準でn文字ずつのチャンクに分割する。
    def self.split_by_runes(s : String, n : Int32) : Array(String)
      chunks = [] of String
      i = 0
      while i < s.size
        e = Math.min(i + n, s.size)
        chunks << s[i, e - i]
        i = e
      end
      chunks
    end
  end
end
