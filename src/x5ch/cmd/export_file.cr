require "file_utils"
require "path"
require "./config"
require "../fivechbrowser/browser"
require "../fivechbrowser/export"

module X5ch
  module Cmd
    # ファイル名に使えない文字。
    FILENAME_UNSAFE_PATTERN = /[\/\\:*?"<>|\r\n]/

    # `X5ch export`(TUI内エクスポート機能)の保存先ディレクトリ。
    # X5CH_EXPORT_DIR未設定時は「x5chを実行したカレントディレクトリ」直下の x5ch_exports。
    # (ホームディレクトリ基準にすると、Codespaces/Colab等で実行ディレクトリと
    #  ホームディレクトリが別階層/別マウントになっている環境で見つけにくくなるため)
    def self.export_output_dir : String
      env_or("X5CH_EXPORT_DIR", File.join(Dir.current, "x5ch_exports"))
    end

    # OSのファイル名として不正な文字を "_" に置換し、長すぎる場合は切り詰める。
    def self.sanitize_filename(s : String) : String
      cleaned = s.gsub(FILENAME_UNSAFE_PATTERN, "_").strip
      cleaned = cleaned[0, 80] if cleaned.size > 80
      cleaned.empty? ? "no_title" : cleaned
    end

    # 保存ファイル名(拡張子抜き)。dat_file(スレ立て時刻)+スレタイトルで構成し、
    # 同じスレッドの複数回エクスポートでもファイルが一意に定まるようにする。
    def self.export_filename_base(dat_file : String, title : String) : String
      dat_num = dat_file.sub(/\.dat$/, "")
      "#{dat_num}_#{sanitize_filename(title)}"
    end

    # 指定スレッドを取得し、json または markdown いずれか1ファイルに書き出す。
    # TUI(Pager/Selector双方)から呼ばれる共通処理。例外は投げず、成否どちらも
    # ユーザーにそのまま表示できるメッセージ文字列を返す。
    def self.perform_export(browser : X5ch::FivechBrowser::Browser, board_url : String, dat_file : String, as_markdown : Bool) : String
      result =
        begin
          browser.export_thread_data(board_url, dat_file)
        rescue ex : X5ch::FivechBrowser::ThreadGoneError
          return "エクスポート失敗: スレッドはdat落ちしています"
        rescue ex : X5ch::FivechBrowser::BrowserError
          url_part = ex.url ? " (URL: #{ex.url})" : ""
          return "エクスポート失敗: #{ex.message}#{url_part}"
        rescue ex
          return "エクスポート失敗: #{ex.class}: #{ex.message}"
        end

      dir = export_output_dir
      begin
        FileUtils.mkdir_p(dir)
      rescue ex
        return "エクスポート失敗: 保存先ディレクトリを作成できません (#{ex.message})"
      end

      base = export_filename_base(dat_file, result.thread.title)
      ext = as_markdown ? "md" : "json"
      path = File.join(dir, "#{base}.#{ext}")
      body = as_markdown ? result.to_markdown : result.to_pretty_json

      begin
        File.write(path, body)
      rescue ex
        return "エクスポート失敗: 書き込みエラー (#{ex.message})"
      end

      "エクスポートしました: #{path}"
    end
  end
end