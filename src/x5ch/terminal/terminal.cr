require "termios"

module X5ch
  module Terminal
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
