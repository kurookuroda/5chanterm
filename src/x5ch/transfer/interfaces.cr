require "json"
require "../fivechbrowser/types"

module X5ch
  module Transfer
    # Task はDiscordへの転送待ちタスク。Ruby版のキュー要素(title/board_url/dat_file)に対応。
    class Task
      include JSON::Serializable

      property title : String
      @[JSON::Field(key: "board_url")]
      property board_url : String
      @[JSON::Field(key: "dat_file")]
      property dat_file : String

      def initialize(@title, @board_url, @dat_file)
      end
    end

    # ThreadDataFetcher は fivechbrowser::Browser#get_thread_data と同じシグネチャの抽象。
    module ThreadDataFetcher
      abstract def get_thread_data(t : X5ch::FivechBrowser::ThreadInfo) : Array(X5ch::FivechBrowser::Post)
    end

    # HistoryUpdater は history::Manager が満たすべき抽象。
    module HistoryUpdater
      abstract def get_last_read(board_url : String, dat_file : String) : Int32
      abstract def get_discord_thread_id(board_url : String, dat_file : String) : String?
      abstract def update_history(t : X5ch::FivechBrowser::ThreadInfo, res_num : Int32, discord_thread_id : String?) : Nil
    end

    # DiscordClient はDiscordへの送信を担う抽象(discordモジュール側の実装をここに注入する)。
    # API呼び出し自体が失敗した場合は DiscordAPIError (かそれをラップした例外) を送出する想定。
    module DiscordClient
      abstract def create_thread(title : String) : String
      abstract def send_message(discord_thread_id : String, post : X5ch::FivechBrowser::Post) : Nil
    end

    # DiscordAPIError はDiscord API呼び出しレベルでの失敗(例: 429)を表す。
    # discordモジュールの実装はこの型を送出することで、Workerが正しくリトライ分類できる。
    class DiscordAPIError < Exception
      def initialize(msg : String)
        super("Discord API Error: #{msg}")
      end
    end
  end
end
