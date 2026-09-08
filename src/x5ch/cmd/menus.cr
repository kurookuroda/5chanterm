require "../selector/selector"
require "../history/manager"
require "../transfer/worker"

module X5ch
  module Cmd
    # 転送待機列の一覧表示・削除画面。Ruby版 manage_queue に対応。
    # 戻り値はCtrl+Cで中断されたかどうか(呼び出し元のSelector.runへ伝播させるため)。
    def self.manage_queue(io : Selector::TermIO, worker : Transfer::Worker) : Bool
      loop do
        items = worker.queue_list

        io.print("\e[H\e[2J")
        io.println("=== 転送待機列の管理 ===")
        io.println(" 現在の待機数: #{items.size}")
        io.println(" 削除したいタスクの番号を入力してください。")
        io.println(" (b: 戻る)")
        io.println("------------------------------------------------")
        if items.empty?
          io.println(" (待機中のタスクはありません)")
        else
          items.each_with_index do |item, i|
            io.println("[#{i}] #{item.title}")
          end
        end
        io.print("\r\nCommand > ")

        b =
          begin
            io.read_key
          rescue
            return false
          end
        return true if b == 0x03
        return false if b.chr == 'b' || b.chr == 'q'

        io.print(b.chr.to_s)
        rest =
          begin
            io.read_line
          rescue Selector::InterruptedError
            return true
          rescue
            return false
          end
        input = (b.chr.to_s + rest).strip
        if idx = input.to_i?
          deleted = worker.delete_at(idx)
          if deleted
            io.println("\r\n\e[31m削除しました: #{deleted.title}\e[0m")
            sleep 1.seconds
          end
        end
      end
    end

    # 閲覧履歴の一覧表示・削除画面(メインメニューの'H'相当)。Ruby版 manage_history に対応。
    def self.manage_history(io : Selector::TermIO, hist : X5ch::History::Manager) : Bool
      loop do
        items = hist.get_recent_threads

        io.print("\e[H\e[2J")
        io.println("=== 閲覧履歴の管理 (削除) ===")
        io.println(" 削除したい履歴の番号を入力してください。")
        io.println(" (b: 戻る)")
        io.println("------------------------------------------------")
        if items.empty?
          io.println(" (履歴はありません)")
        else
          items.each_with_index do |item, i|
            io.println("[#{i}] #{item.thread_info.title} (Read: #{item.thread_info.last_read})")
          end
        end
        io.print("\r\nDelete No > ")

        b =
          begin
            io.read_key
          rescue
            return false
          end
        return true if b == 0x03
        return false if b.chr == 'b' || b.chr == 'q'

        io.print(b.chr.to_s)
        rest =
          begin
            io.read_line
          rescue Selector::InterruptedError
            return true
          rescue
            return false
          end
        input = (b.chr.to_s + rest).strip
        idx = input.to_i?
        next if idx.nil?

        if idx >= 0 && idx < items.size
          target = items[idx]
          if hist.delete_thread(target.thread_info.board_url, target.thread_info.dat_file)
            io.println("\r\n\e[31m履歴を削除しました: #{target.thread_info.title}\e[0m")
            sleep 800.milliseconds
          end
        else
          io.println("\r\n無効な番号です")
          sleep 500.milliseconds
        end
      end
    end
  end
end
