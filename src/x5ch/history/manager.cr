require "json"
require "../fivechbrowser/types"
require "../fivechbrowser/interfaces"
require "../transfer/interfaces"

module X5ch
  module History
    private class Entry
      include JSON::Serializable

      property res : Int32
      property title : String
      @[JSON::Field(key: "board_url")]
      property board_url : String
      @[JSON::Field(key: "dat_file")]
      property dat_file : String
      property timestamp : Int64
      @[JSON::Field(key: "discord_thread_id", emit_null: false)]
      property discord_thread_id : String?

      def initialize(@res, @title, @board_url, @dat_file, @timestamp, @discord_thread_id = nil)
      end
    end

    # RecentThread はソート用にタイムスタンプを保持したまま返すための型。
    # Go版は ThreadInfo を埋め込み(struct embedding)しているが、Crystalには
    # 同等の埋め込み機構が無いため、ThreadInfoを保持するプロパティとして持たせる。
    class RecentThread
      property thread_info : X5ch::FivechBrowser::ThreadInfo
      property timestamp : Int64

      def initialize(@thread_info, @timestamp)
      end
    end

    # Manager は閲覧履歴をJSONファイルに永続化する。Ruby版の HistoryManager、
    # Go版の *Manager に対応し、fivechbrowser::HistoryStore を実装する。
    class Manager
      include X5ch::FivechBrowser::HistoryStore
      include X5ch::Transfer::HistoryUpdater

      def initialize(@file_path : String)
        @mutex = Mutex.new
        @data = {} of String => Entry
        load
      end

      private def load : Nil
        return unless File.exists?(@file_path)
        body = File.read(@file_path)
        begin
          @data = Hash(String, Entry).from_json(body)
        rescue JSON::ParseException
          @data = {} of String => Entry
        end
      end

      private def save : Bool
        File.write(@file_path, @data.to_pretty_json)
        true
      rescue
        false
      end

      private def normalize_url(raw_url : String) : String
        u = raw_url
        u = u.sub(/^https?:\/\//, "")
        u = u.sub(/^www\./, "")
        u = u.sub(/\/$/, "")
        u = u.gsub("2ch.net", "5ch.io")
        u = u.gsub("5ch.net", "5ch.io")
        u
      end

      private def generate_key(board_url : String, dat_file : String) : String
        "#{normalize_url(board_url)}::#{dat_file}"
      end

      def get_last_read(board_url : String, dat_file : String) : Int32
        @mutex.synchronize do
          @data[generate_key(board_url, dat_file)]?.try(&.res) || 0
        end
      end

      def get_discord_thread_id(board_url : String, dat_file : String) : String?
        @mutex.synchronize do
          @data[generate_key(board_url, dat_file)]?.try(&.discord_thread_id)
        end
      end

      def exists?(board_url : String, dat_file : String) : Bool
        @mutex.synchronize do
          @data.has_key?(generate_key(board_url, dat_file))
        end
      end

      def has_history_in_board?(board_url : String) : Bool
        @mutex.synchronize do
          target = normalize_url(board_url)
          @data.values.any? { |e| normalize_url(e.board_url) == target }
        end
      end

      def has_history_in_category?(boards : Array(X5ch::FivechBrowser::Board)) : Bool
        boards.any? { |b| has_history_in_board?(b.url) }
      end

      def add_new_thread(title : String, board_url : String, dat_file : String) : Nil
        @mutex.synchronize do
          key = generate_key(board_url, dat_file)
          next if @data.has_key?(key)

          @data[key] = Entry.new(
            res: 0,
            title: title,
            board_url: board_url,
            dat_file: dat_file,
            timestamp: Time.utc.to_unix,
          )
          save
        end
      end

      def delete_thread(board_url : String, dat_file : String) : Bool
        @mutex.synchronize do
          key = generate_key(board_url, dat_file)
          next false unless @data.has_key?(key)
          @data.delete(key)
          save
          true
        end
      end

      def update_history(t : X5ch::FivechBrowser::ThreadInfo, res_num : Int32, discord_thread_id : String? = nil) : Nil
        @mutex.synchronize do
          key = generate_key(t.board_url, t.dat_file)
          current = @data[key]?

          new_res = current ? Math.max(res_num, current.res) : res_num
          new_discord_id = (discord_thread_id && !discord_thread_id.empty?) ? discord_thread_id : current.try(&.discord_thread_id)

          @data[key] = Entry.new(
            res: new_res,
            title: t.title,
            board_url: t.board_url,
            dat_file: t.dat_file,
            timestamp: Time.utc.to_unix,
            discord_thread_id: new_discord_id,
          )
          save
        end
      end

      # 履歴を新しい順(タイムスタンプ降順)に返す。
      def get_recent_threads : Array(RecentThread)
        @mutex.synchronize do
          threads = @data.values.map do |e|
            RecentThread.new(
              thread_info: X5ch::FivechBrowser::ThreadInfo.new(
                dat_file: e.dat_file,
                title: e.title,
                board_url: e.board_url,
                last_read: e.res,
              ),
              timestamp: e.timestamp,
            )
          end
          threads.sort! { |a, b| b.timestamp <=> a.timestamp }
          threads
        end
      end
    end
  end
end
