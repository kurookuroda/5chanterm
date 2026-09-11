require "../terminal/terminal"
require "../fivechbrowser/types"

module X5ch
  module Pager
    enum ContentType
      Header
      UnreadMarker
      SystemMsg
      Post
      Separator
      Error
    end

    # ContentItem はPagerが受け取る1項目。用途に応じて使うフィールドが変わる。
    struct ContentItem
      property type : ContentType
      property thread : X5ch::FivechBrowser::ThreadInfo?
      property post : X5ch::FivechBrowser::Post?
      property message : String

      def initialize(@type : ContentType, @thread : X5ch::FivechBrowser::ThreadInfo? = nil, @post : X5ch::FivechBrowser::Post? = nil, @message : String = "")
      end
    end

    enum Style
      None
      Bold
      Red
      Dim
      BgBlue
    end

    private struct Line
      property text : String
      property style : Style

      def initialize(@text : String, @style : Style)
      end
    end

    private struct LineInfo
      property thread : X5ch::FivechBrowser::ThreadInfo?
      property res : Int32

      def initialize(@thread : X5ch::FivechBrowser::ThreadInfo?, @res : Int32)
      end
    end

    # Result はPager終了時に返す、最後に見ていた位置の情報。
    struct Result
      property thread : X5ch::FivechBrowser::ThreadInfo?
      property res : Int32

      def initialize(@thread : X5ch::FivechBrowser::ThreadInfo?, @res : Int32)
      end
    end

    # Pager はスクロール可能なテキストビューア(Ruby版 ViPager に対応)。
    class Pager
      # on_export: 'e'(Markdown)/'E'(JSON)キー押下時に呼ばれる。
      # 引数は(表示中スレッドのThreadInfo, Markdown出力ならtrue)、戻り値は画面に一時表示する結果メッセージ。
      # nilなら(show_recent_streamなど複数スレッド表示時)キーは無視される。
      def initialize(content : Array(ContentItem), @on_export : Proc(X5ch::FivechBrowser::ThreadInfo, Bool, String)? = nil)
        @lines = [] of Line
        @line_info = [] of LineInfo
        @jump_index = 0
        @export_thread = nil.as(X5ch::FivechBrowser::ThreadInfo?)
        prepare_content(content)
      end

      private def add_line(text : String, thread : X5ch::FivechBrowser::ThreadInfo?, res : Int32, style : Style) : Nil
        @lines << Line.new(text, style)
        @line_info << LineInfo.new(thread, res)
      end

      private def prepare_content(content : Array(ContentItem)) : Nil
        @jump_index = 0

        content.each do |item|
          case item.type
          in .header?
            th = item.thread
            @export_thread = th if @export_thread.nil?
            add_line(" " * 60, th, 0, Style::BgBlue)
            title = th.try(&.title) || ""
            url = th.try(&.url) || ""
            last_read = th.try(&.last_read) || 0
            add_line("【#{title}】", th, 0, Style::Bold)
            add_line(" URL: #{url} (既読: #{last_read})", th, 0, Style::None)
            add_line("=" * 60, th, 0, Style::None)
          in .unread_marker?
            @jump_index = Math.max(@lines.size - 10, 0)
            add_line("▼▼▼ ここから未読 ▼▼▼", item.thread, 0, Style::Red)
          in .system_msg?
            add_line("  #{item.message}", item.thread, 0, Style::Dim)
          in .post?
            post = item.post
            th = item.thread
            next unless post
            header = "#{post.num} : #{post.name} [#{post.date}]"
            add_line(header, th, post.num, Style::Bold)
            split_lines(post.message).each do |l|
              add_line("  #{l}", th, post.num, Style::None)
            end
            add_line("-" * 60, th, post.num, Style::Dim)
          in .separator?
            add_line("", nil, 0, Style::None)
            add_line("      ( 次のスレッドへ続く )      ", nil, 0, Style::Dim)
            add_line("", nil, 0, Style::None)
          in .error?
            add_line("!!! #{item.message} !!!", item.thread, 0, Style::Red)
          end
        end

        add_line("(End of Stream)", nil, 0, Style::Dim)
      end

      # Rubyの String#each_line 相当(末尾の空行を含めない)に分割する。
      private def split_lines(s : String) : Array(String)
        parts = s.split("\n")
        parts.pop if parts.size > 0 && parts.last.empty?
        parts
      end

      # 端末をrawモードにし、キー入力によるスクロール操作を受け付ける。
      # 'q'で終了し、その時点の閲覧位置を Result として返す(コンテキストが無ければnil)。
      #
      # reader は main.cr が起動時に1つだけ生成し、全画面で使い回す共有KeyReader
      # (Selector.run と同じ理由——画面ごとに専用の読み取りFiberを作ると、
      #  前の画面のFiberが次の画面の入力を横取りする実バグがあったため)。
      def start(reader : X5ch::Terminal::KeyReader, output : IO, fd : Int32) : Result?
        original_termios = X5ch::Terminal.enable_raw_mode(fd)

        begin
          cols, rows = X5ch::Terminal.get_size(fd)

          current_line = @jump_index
          max_scroll = Math.max(@lines.size - rows, 0)
          current_line = max_scroll if current_line > max_scroll

          loop do
            max_scroll = Math.max(@lines.size - rows, 0)
            render(output, current_line, rows, cols)

            byte =
              begin
                reader.read_byte
              rescue
                return nil
              end

            current_context = context_at(current_line, rows)

            next if byte >= '0'.ord && byte <= '9'.ord

            case byte
            when 'q'.ord
              return current_context.nil? ? nil : Result.new(current_context.thread, current_context.res)
            when 'j'.ord, 0x0d, 0x0a
              current_line += 1 if current_line < max_scroll
            when 'k'.ord
              current_line -= 1 if current_line > 0
            when 'f'.ord, ' '.ord
              current_line = Math.min(current_line + rows - 1, max_scroll)
            when 0x04 # Ctrl-D
              current_line = Math.min(current_line + rows // 2, max_scroll)
            when 'b'.ord
              current_line = Math.max(current_line - (rows - 1), 0)
            when 0x15 # Ctrl-U
              current_line = Math.max(current_line - rows // 2, 0)
            when 'g'.ord
              current_line = 0
            when 'G'.ord
              current_line = max_scroll
            when 'e'.ord, 'E'.ord
              if (cb = @on_export) && (th = @export_thread)
                as_markdown = byte == 'e'.ord
                output.print("\r\n\e[Kエクスポート中...")
                output.flush
                message =
                  begin
                    cb.call(th, as_markdown)
                  rescue ex
                    "エクスポート失敗: #{ex.class}: #{ex.message}"
                  end
                output.print("\r\n\e[K#{message}\r\n")
                output.flush
                sleep 1.seconds
              end
            when 0x1b # ESC
              b2 =
                begin
                  reader.read_byte
                rescue
                  next
                end
              next if b2 != '['.ord
              b3 =
                begin
                  reader.read_byte
                rescue
                  next
                end
              case b3
              when 'A'.ord
                current_line -= 1 if current_line > 0
              when 'B'.ord
                current_line += 1 if current_line < max_scroll
              end
            end
          end
        ensure
          X5ch::Terminal.restore_mode(fd, original_termios)
        end
      end

      # 表示中の最下行から上方向に走査し、最初に見つかったレス情報を返す。
      private def context_at(offset : Int32, rows : Int32) : LineInfo?
        visible_bottom = Math.min(offset + rows - 1, @lines.size - 1)
        visible_bottom.downto(0) do |idx|
          info = @line_info[idx]
          return info if info.thread && info.res > 0
        end
        nil
      end

      private def render(output : IO, offset : Int32, rows : Int32, cols : Int32) : Nil
        output.print("\e[H\e[2J")

        e = Math.min(offset + rows, @lines.size)
        o = offset > e ? e : offset

        @lines[o, e - o].each do |l|
          display_text = X5ch::Terminal.truncate_by_width(l.text, cols, cols <= 3 ? "" : "...")
          case l.style
          when .bold?
            output.print("\e[1m#{display_text}\e[0m\r\n")
          when .red?
            output.print("\e[31m#{display_text}\e[0m\r\n")
          when .dim?
            output.print("\e[2m#{display_text}\e[0m\r\n")
          when .bg_blue?
            output.print("\e[44;1m#{display_text}\e[0m\r\n")
          else
            output.print("#{display_text}\r\n")
          end
        end
        output.flush
      end
    end
  end
end