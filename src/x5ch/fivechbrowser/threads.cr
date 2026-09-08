require "./types"
require "./fetch"
require "./menu"
require "./interfaces"

module X5ch
  module FivechBrowser
    class ThreadsError < Exception
    end

    SUBJECT_LINE_PATTERN = /^(\d+\.dat)<>(.*?)\((\d+)\)\s*$/

    # 板のスレッド一覧(subject.txt)を取得し、勢い順(降順)に並べて返す。
    #
    # `board` は class(参照型)なので、subject_urlがリダイレクトされた場合に
    # `board.url` を書き換えると、この関数の呼び出し元が保持している同じ Board
    # インスタンスにも反映される(Go版の *Board と同じ挙動)。
    def self.get_threads(fetcher : Fetcher, history : HistoryStore, board : Board) : Array(ThreadInfo)
      subject_url = board.url + "subject.txt"

      body, final_url =
        begin
          fetcher.fetch(subject_url)
        rescue ex : FetchError
          raise ThreadsError.new("スレッド一覧の取得に失敗しました: #{ex.message}")
        end

      if final_url != subject_url
        board.url = final_url.sub(/subject\.txt$/, "")
      end

      data = decode_to_utf8(body)

      now = Time.utc.to_unix
      threads = [] of ThreadInfo

      data.split("\n").each do |line|
        m = SUBJECT_LINE_PATTERN.match(line)
        next unless m

        dat_file = m[1]
        title = m[2].strip
        count = m[3].to_i? 
        next unless count

        ikioi = calc_ikioi(dat_file, count, now)
        last_read = history.get_last_read(board.url, dat_file)

        threads << ThreadInfo.new(
          dat_file: dat_file,
          title: title,
          count: count,
          ikioi: ikioi,
          board_url: board.url,
          last_read: last_read,
        )
      end

      threads.sort! { |a, b| b.ikioi <=> a.ikioi }
      threads
    end

    def self.calc_ikioi(dat_file : String, count : Int32, now : Int64) : Float64
      ts_str = dat_file.sub(/\.dat$/, "")
      ts = ts_str.to_i64?
      return 0.0 unless ts

      elapsed_seconds = now - ts
      elapsed_seconds = 1_i64 if elapsed_seconds < 1
      elapsed_days = elapsed_seconds.to_f64 / 86400.0

      count.to_f64 / elapsed_days
    end
  end
end
