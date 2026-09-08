module X5ch
  module FivechBrowser
    # HistoryStore は閲覧履歴の永続化を担う抽象。Ruby版の HistoryManager に対応。
    # 具象実装(history.cr側のHistoryManager等)はこれらのメソッドを実装する想定。
    # Go版のinterfaceと異なりCrystalには構造的部分型が無いため、
    # 実装クラスは `include HistoryStore` して明示的に適合を宣言する。
    module HistoryStore
      abstract def get_last_read(board_url : String, dat_file : String) : Int32
      abstract def exists?(board_url : String, dat_file : String) : Bool
      abstract def add_new_thread(title : String, board_url : String, dat_file : String) : Nil
    end
  end
end
