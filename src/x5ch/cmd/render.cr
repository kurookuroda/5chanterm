require "../fivechbrowser/types"

module X5ch
  module Cmd
    # ThreadItemState はスレッド一覧画面での表示用ラッパー。is_queued は Selector::Item(T).value に
    # 持たせる必要があるため(Ruby版の item[:is_queued] 相当)、ThreadInfo単体ではなくこの構造体をTとする。
    struct ThreadItemState
      property thread : X5ch::FivechBrowser::ThreadInfo
      property is_queued : Bool

      def initialize(@thread : X5ch::FivechBrowser::ThreadInfo, @is_queued : Bool = false)
      end
    end

    # 「★ 最近読んだスレッド」エントリの表示。Ruby版: display_name = "\e[1;36m#{title}\e[0m"
    def self.render_recent_entry(title : String) : String
      "  \e[1;36m#{title}\e[0m"
    end

    # カテゴリ/板一覧の表示(履歴の有無だけで分岐)。
    # Ruby: prefix_mark = "\e[36m*\e[0m", display_name = "\e[36m#{title} (履歴あり)\e[0m"
    def self.render_category_or_board_item(title : String, has_history : Bool) : String
      return "\e[36m*\e[0m \e[36m#{title} (履歴あり)\e[0m" if has_history
      "  #{title}"
    end

    # スレッド一覧の表示。Ruby版 select_item の mode==:thread 分岐に対応。
    def self.render_thread_item(t : X5ch::FivechBrowser::ThreadInfo, is_queued : Bool) : String
      has_new = t.has_new?
      has_history_or_queued = t.last_read > 0 || is_queued

      mark = " "
      mark = "\e[31m+\e[0m" if has_new

      display_name = t.title
      prefix_mark = " "

      if has_history_or_queued
        display_name = "\e[36m#{t.title}\e[0m"
        unless has_new
          prefix_mark = "\e[36m✔\e[0m"
          mark = "\e[32m.\e[0m"
        end
      end

      info = t.ikioi > 0 ? "#{mark} (#{t.count}/#{t.ikioi.to_i})" : "#{mark} (#{t.count})"

      "#{prefix_mark}#{info} #{display_name}"
    end

    # 'h' キー押下時のヘルプ画面。mode に応じて H の説明文だけが変わる。
    # Ruby版 select_item 内 when 'h' に対応。
    def self.help_text(mode : String) : String
      base = "=== キー操作ヘルプ ===\r\n" \
             " 数字  : 決定 / Enter : 次ページ\r\n" \
             " m     : [NEW] 転送キューに追加\r\n" \
             " t     : [NEW] 転送キューの管理\r\n"

      case mode
      when "category"
        base += " H     : [NEW] 閲覧履歴の管理(削除)\r\n"
      when "thread"
        base += " H     : [NEW] 選択したスレッドの履歴を削除\r\n"
      end

      base += " s     : 検索 / r : リロード / q : 終了 / b : 戻る\r\n"
      base += " Ctrl+C: 待機列を保存して終了\r\n"
      base
    end
  end
end
