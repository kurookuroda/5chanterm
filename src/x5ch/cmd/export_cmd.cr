require "./config"
require "./search_read_cmd"
require "../fivechbrowser/browser"

module X5ch
  module Cmd
    # `x5ch export <board_url> <dat_file> [--since-num N]` を処理する。
    # 対話TUIのロック取得・rawモード設定を一切経由しない、非対話の使い捨てコマンドとして実装。
    def self.run_export_command(args : Array(String)) : Nil
      since_num = 0
      rest = [] of String

      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--since-num"
          i += 1
          since_num = args[i]?.try(&.to_i?) || 0
        elsif arg.starts_with?("--since-num=")
          since_num = arg.split("=", 2)[1].to_i? || 0
        else
          rest << arg
        end
        i += 1
      end

      if rest.size < 2
        STDERR.puts "使い方: x5ch export <board_url> <dat_file> [--since-num N]"
        STDERR.puts "例:     x5ch export https://mao.5ch.io/linux/ 1765829109.dat"
        exit(1)
      end
      board_url = rest[0]
      dat_file = rest[1]

      cfg = load_config
      # export専用の用途では閲覧履歴を一切参照・更新しないため、NullHistoryで構わない
      # (ExportThreadDataはhistoryフィールドを使用しない)。
      browser = X5ch::FivechBrowser::Browser.new(cfg.user_agent, NullHistory.new, cfg.cache_expiration)

      result =
        begin
          browser.export_thread_data(board_url, dat_file, since_num)
        rescue ex : X5ch::FivechBrowser::ThreadGoneError
          STDERR.puts "スレッドはdat落ちしています"
          exit(1)
        rescue ex
          STDERR.puts "エラー: #{ex.message}"
          exit(1)
        end

      puts result.to_pretty_json
    end
  end
end
