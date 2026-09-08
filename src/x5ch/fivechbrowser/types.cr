module X5ch
  module FivechBrowser
    # Board は5chの1つの板を表す。Ruby版の { title:, url: } に対応。
    #
    # class(参照型)にしている点がGo版の `Board` (素朴なstruct)と異なる。
    # Go版は `GetThreads(f *Fetcher, history HistoryStore, board *Board)` のように
    # *Board (ポインタ) で受け取り、リダイレクト発生時に board.URL を
    # 呼び出し元のBoardごと書き換える設計になっている
    # (browser.go の Browser.GetThreads もこの *Board をそのまま貫通させる)。
    # Crystalで同じ「呼び出し元にURL更新が伝播する」挙動を素直に再現するには
    # 値型のstructではなく参照型のclassにする必要がある。
    class Board
      property title : String
      property url : String

      def initialize(@title : String, @url : String)
      end
    end

    # Category はメニュー上の1カテゴリと、そこに属する板一覧。
    # Ruby版の { title:, boards: [...] } に対応。
    struct Category
      property title : String
      property boards : Array(Board)

      def initialize(@title : String, @boards : Array(Board) = [] of Board)
      end
    end

    # ThreadInfo は1スレッドの識別情報と、閲覧に伴って更新される状態を保持する。
    #
    # Go版と同じく、`has_new` は保存フィールドではなく計算メソッドにしている。
    # Ruby版はフィールドとして保存していたため、count や last_read の更新時に
    # 同期し忘れて古い値が残るバグがあった。それを避けるための設計。
    class ThreadInfo
      property dat_file : String
      property title : String
      property count : Int32
      property ikioi : Float64
      property board_url : String
      property last_read : Int32
      property url : String

      def initialize(
        @dat_file : String,
        @title : String = "",
        @count : Int32 = 0,
        @ikioi : Float64 = 0.0,
        @board_url : String = "",
        @last_read : Int32 = 0,
        @url : String = "",
      )
      end

      def has_new? : Bool
        count > last_read
      end
    end

    # Post は1レスを表す。
    struct Post
      property num : Int32
      property name : String
      property date : String
      property message : String

      def initialize(@num : Int32, @name : String, @date : String, @message : String)
      end
    end
  end
end
