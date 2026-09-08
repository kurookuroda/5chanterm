require "json"
require "./types"
require "./fetch"

module X5ch
  module FivechBrowser
    MENU_URL_JSON = "https://menu.5ch.io/bbsmenu.json"
    MENU_URL_HTML = "https://menu.5ch.io/bbsmenu.html"

    class MenuError < Exception
    end

    # --- bbsmenu.json の構造 ---
    class BbsMenuBoardJSON
      include JSON::Serializable
      @[JSON::Field(key: "board_name")]
      property board_name : String?
      property url : String?
    end

    class BbsMenuCategoryJSON
      include JSON::Serializable
      @[JSON::Field(key: "category_name")]
      property category_name : String?
      @[JSON::Field(key: "category_content")]
      property category_content : Array(BbsMenuBoardJSON)?
    end

    class BbsMenuJSON
      include JSON::Serializable
      @[JSON::Field(key: "menu_list")]
      property menu_list : Array(BbsMenuCategoryJSON)?
    end

    # CP932(Shift_JIS)バイト列をUTF-8文字列に変換する。
    # デコードに失敗した場合はGo版(golang.org/x/text)・Ruby版(force_encoding+encode)の
    # どちらも「失敗しても例外にせずそのまま通す」寛容な方針なので、
    # Crystalでも Windows-31J として解釈できない場合は生バイトのまま String 化する
    # (妥当なUTF-8でない可能性があるが、クラッシュはさせない)。
    def self.decode_to_utf8(bytes : Bytes) : String
      String.new(bytes, "Windows-31J")
    rescue ArgumentError
      String.new(bytes)
    end

    # 板メニューをJSON優先・HTML fallbackで取得する。
    def self.get_menu(fetcher : Fetcher) : Array(Category)
      begin
        cats = get_menu_from_json(fetcher)
        return cats unless cats.empty?
      rescue
        # JSON失敗時はHTMLへフォールバック
      end

      begin
        cats = get_menu_from_html(fetcher)
        return cats unless cats.empty?
      rescue
      end

      raise MenuError.new("メニューの取得に失敗しました(JSON/HTML両方とも失敗)")
    end

    def self.get_menu_from_json(fetcher : Fetcher, url : String = MENU_URL_JSON) : Array(Category)
      body, _ = fetcher.fetch(url)

      data =
        begin
          BbsMenuJSON.from_json(String.new(body))
        rescue ex : JSON::ParseException
          raise MenuError.new("JSON解析エラー: #{ex.message}")
        end

      categories = [] of Category
      (data.menu_list || [] of BbsMenuCategoryJSON).each do |cat|
        boards = [] of Board
        (cat.category_content || [] of BbsMenuBoardJSON).each do |b|
          url = b.url
          next if url.nil? || url.empty?
          boards << Board.new(title: b.board_name || "", url: normalize_menu_url(url))
        end
        categories << Category.new(title: cat.category_name || "", boards: boards) unless boards.empty?
      end
      categories
    end

    HTML_MENU_PATTERN = /(?:<B>([^<]+)<\/B>)|(?:<A HREF=["']?([^ >"']+)["']?[^>]*>([^<]+)<\/A>)/i

    def self.get_menu_from_html(fetcher : Fetcher, url : String = MENU_URL_HTML) : Array(Category)
      body, _ = fetcher.fetch(url)
      html = decode_to_utf8(body)

      categories = [] of Category
      current_category = ""
      current_boards = [] of Board
      has_category = false

      html.scan(HTML_MENU_PATTERN) do |m|
        if (cat_name = m[1]?) && !cat_name.empty?
          categories << Category.new(title: current_category, boards: current_boards) if has_category && !current_boards.empty?
          current_category = cat_name.strip
          current_boards = [] of Board
          has_category = true
        elsif (url = m[2]?) && !url.empty?
          unless url.includes?("5ch.io") || url.includes?("5ch.net") ||
                 url.includes?("2ch.net") || url.includes?("bbspink.com")
            next
          end
          normalized = normalize_menu_url(url)
          if has_category
            current_boards << Board.new(title: (m[3]? || "").strip, url: normalized)
          end
        end
      end
      categories << Category.new(title: current_category, boards: current_boards) if has_category && !current_boards.empty?

      categories
    end

    def self.normalize_menu_url(url : String) : String
      url = url.gsub("2ch.net", "5ch.io")
      url = url.gsub("5ch.net", "5ch.io")
      url = "https:" + url[5..] if url.starts_with?("http:")
      url += "/" unless url.ends_with?("/")
      url
    end
  end
end
