require "path"

module X5ch
  module Cmd
    # AppConfig は Ruby版 config.rb (Config module) に対応する設定値。
    # Rubyはコードを直接評価する設定ファイルだったが、Go版は環境変数 + ホームディレクトリの
    # デフォルトパスを使うシンプルな方式にしている(意図的な設計変更)。Crystal版もこれを踏襲する。
    struct AppConfig
      property discord_bot_token : String
      property discord_channel_id : String
      property history_file : String
      property queue_file : String
      property lock_file : String
      property pid_file : String
      property cache_expiration : Time::Span
      property user_agent : String

      def initialize(
        @discord_bot_token : String,
        @discord_channel_id : String,
        @history_file : String,
        @queue_file : String,
        @lock_file : String,
        @pid_file : String,
        @cache_expiration : Time::Span,
        @user_agent : String,
      )
      end
    end

    def self.env_or(key : String, fallback : String) : String
      v = ENV[key]?
      (v && !v.empty?) ? v : fallback
    end

    def self.load_config : AppConfig
      home = Path.home.to_s

      AppConfig.new(
        discord_bot_token: ENV["X5CH_DISCORD_BOT_TOKEN"]? || "",
        discord_channel_id: ENV["X5CH_DISCORD_CHANNEL_ID"]? || "",
        history_file: env_or("X5CH_HISTORY_FILE", File.join(home, ".x5ch_history.json")),
        queue_file: env_or("X5CH_QUEUE_FILE", File.join(home, ".x5ch_queue.json")),
        lock_file: env_or("X5CH_LOCK_FILE", File.join(home, ".x5ch.lock")),
        pid_file: env_or("X5CH_PID_FILE", File.join(home, ".x5ch.pid")),
        cache_expiration: 300.seconds,
        user_agent: "w3m/0.5.3",
      )
    end
  end
end
