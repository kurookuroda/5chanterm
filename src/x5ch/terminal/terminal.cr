require "termios"

module X5ch
  module Terminal
    # KeyReader は標準入力等から1バイトずつ読み続ける背景Fiberを1本だけ持つ、
    # プロセス寿命を通じて使い回すための共有リーダー。
    #
    # 経緯: 以前は Selector.run / (旧設計の) Pager が呼び出されるたびに
    # 独自の背景Fiberを起動していたが、そのFiberには止める手段が無く、
    # 呼び出し終了後も生き残って次の画面の入力を横取りする実バグがあった
    # (Go版 selector.go の startKeyReader も同じ構造で、この欠陥は
    # Go版オリジナルの設計に由来する)。PTYでの実測で「1回目のEnterが
    # 消え、2回目でようやく反応する」という形で確実に再現することを確認済み。
    # 対策として、画面遷移のたびに使い捨てのFiberを作るのをやめ、
    # main.cr が起動時に1つだけ生成した KeyReader を全画面で使い回す設計にした。
    class KeyReader
      def initialize(@io : IO)
        @key_channel = Channel(UInt8).new
        @error_channel = Channel(Exception).new(1)
        spawn do
          loop do
            byte = @io.read_byte
            if byte.nil?
              @error_channel.send(IO::EOFError.new)
              break
            end
            @key_channel.send(byte)
          end
        rescue ex
          @error_channel.send(ex)
        end
      end

      # 1バイト読めるまでブロックする。EOF/IOエラー時は例外を送出する。
      def read_byte : UInt8
        select
        when b = @key_channel.receive
          b
        when ex = @error_channel.receive
          raise ex
        end
      end

      # Selector.run 等、キー用チャネルとエラー用チャネルを直接必要とする箇所向け。
      def channels : {Channel(UInt8), Channel(Exception)}
        {@key_channel, @error_channel}
      end
    end

    # --- raw mode ---
    #
    # Crystal 1.11.2 の IO::FileDescriptor#raw!/#cooked! は、内部の
    # system_console_mode ヘルパーが ensure で常に「呼び出し前の設定」に
    # 戻してしまうため、実際には端末モードを恒久的に変更できない
    # (実測で確認済み: raw! 呼び出し前後で termios の内容が一切変化しない)。
    # そのため、Go版の term.MakeRaw/term.Restore に相当する処理を
    # tcgetattr/cfmakeraw/tcsetattr で自前実装している。
    def self.enable_raw_mode(fd : Int32) : ::LibC::Termios
      original = ::LibC::Termios.new
      ::LibC.tcgetattr(fd, pointerof(original))
      raw = original
      ::LibC.cfmakeraw(pointerof(raw))
      if ::LibC.tcsetattr(fd, ::LibC::TCSANOW, pointerof(raw)) != 0
        raise IO::Error.from_errno("tcsetattr")
      end
      original
    end

    def self.restore_mode(fd : Int32, original : ::LibC::Termios) : Nil
      orig = original
      ::LibC.tcsetattr(fd, ::LibC::TCSANOW, pointerof(orig))
    end

    lib LibTerm
      struct Winsize
        ws_row : UInt16
        ws_col : UInt16
        ws_xpixel : UInt16
        ws_ypixel : UInt16
      end
      TIOCGWINSZ = 0x5413
      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    end

    # 端末の行数・列数を取得する。取得できない場合(TTYでない等)は80x24を返す。
    # golang.org/x/term の GetSize に相当。Crystal標準には無いためFFIで直接ioctlを呼ぶ。
    def self.get_size(fd : Int32) : {Int32, Int32}
      ws = LibTerm::Winsize.new
      ret = LibTerm.ioctl(fd, LibTerm::TIOCGWINSZ, pointerof(ws))
      return {80, 24} if ret != 0 || ws.ws_col == 0 || ws.ws_row == 0
      {ws.ws_col.to_i, ws.ws_row.to_i}
    end

    # 東アジアの文字幅(Wide/Fullwidth)判定。go-runewidthの簡易版に相当する自前実装
    # (Crystal標準・利用可能なshardレジストリにはこの用途に適したものが無かったため)。
    # 主要な全角範囲(ひらがな・カタカナ・CJK統合漢字・ハングル・全角記号等)をカバーする。
    private WIDE_RANGES = [
      {0x1100, 0x115F}, {0x2E80, 0x303E}, {0x3041, 0x33FF},
      {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA4CF},
      {0xAC00, 0xD7A3}, {0xF900, 0xFAFF}, {0xFF00, 0xFF60},
      {0xFFE0, 0xFFE6}, {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD},
    ]

    def self.char_width(c : Char) : Int32
      cp = c.ord
      return 0 if cp == 0
      WIDE_RANGES.each do |(lo, hi)|
        return 2 if cp >= lo && cp <= hi
      end
      1
    end

    def self.string_width(s : String) : Int32
      width = 0
      s.each_char { |c| width += char_width(c) }
      width
    end

    # CSIシーケンス(ESC '[' ... 終端の英字)の先頭 i から、終端文字を含む次のインデックスを返す。
    # chars[i] が ESC '[' で始まっていない場合は i をそのまま返す。
    private def self.skip_ansi_escape(chars : Array(Char), i : Int32) : Int32
      return i unless chars[i] == '\e' && i + 1 < chars.size && chars[i + 1] == '['
      j = i + 2
      while j < chars.size && !((chars[j] >= 'a' && chars[j] <= 'z') || (chars[j] >= 'A' && chars[j] <= 'Z'))
        j += 1
      end
      j += 1 if j < chars.size # 終端文字自体を含める
      j
    end

    # 色付けなどのANSIエスケープシーケンスを保持したまま、表示幅(全角=2)基準でcols以内に
    # 切り詰める。selector.crの項目テキストは色コードが文字列に直接埋め込まれているため
    # (cmd/render.cr参照)、truncate_by_width をそのまま使うとエスケープシーケンスのバイトまで
    # 表示幅としてカウントしてしまい、シーケンスの途中で切れて色指定が壊れる。そのため
    # エスケープシーケンス自体は幅計算から除外しつつバイト列としては保持する専用の実装を用意する。
    # 端末幅より長い行を1行のまま出力すると自動折り返しで物理行数がずれ、部分再描画
    # (selector.crの `\e[<行>;1H` によるプロンプト行ジャンプ)の行位置計算が狂う不具合の対策として使う。
    def self.truncate_line_ansi(s : String, cols : Int32) : String
      return "" if cols <= 0
      chars = s.chars

      width = 0
      fits = true
      i = 0
      while i < chars.size
        j = skip_ansi_escape(chars, i)
        if j != i
          i = j
          next
        end
        width += char_width(chars[i])
        if width > cols
          fits = false
          break
        end
        i += 1
      end
      return s if fits

      suffix = cols > 3 ? "..." : ""
      budget = cols > 3 ? cols - 3 : cols

      result = String::Builder.new
      width = 0
      i = 0
      while i < chars.size
        j = skip_ansi_escape(chars, i)
        if j != i
          (i...j).each { |k| result << chars[k] }
          i = j
          next
        end
        w = char_width(chars[i])
        break if width + w > budget
        result << chars[i]
        width += w
        i += 1
      end
      result << suffix
      # 途中で切ったことで開いたままになっている可能性のある色指定をリセットする
      # (色が使われていない行では単なる無害な追加バイトになる)。
      result << "\e[0m"
      result.to_s
    end

    # 表示幅(全角=2、半角=1)基準で文字列をcols以内に切り詰める。
    # go-runewidthのTruncateと同じく、全角文字の途中では切らず、
    # 収まりきらない場合は末尾に suffix を付ける(付けた上でcols以内に収まるようさらに詰める)。
    def self.truncate_by_width(s : String, cols : Int32, suffix : String = "") : String
      return s if string_width(s) <= cols

      suffix_width = string_width(suffix)
      target = cols - suffix_width
      return suffix[0, 0] if target <= 0 # colsが小さすぎる場合は空扱い(go-runewidth準拠の安全側動作)

      result = String::Builder.new
      width = 0
      s.each_char do |c|
        w = char_width(c)
        break if width + w > target
        result << c
        width += w
      end
      "#{result.to_s}#{suffix}"
    end
  end
end
