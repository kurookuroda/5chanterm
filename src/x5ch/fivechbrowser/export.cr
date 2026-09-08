require "json"
require "html"
require "./types"
require "./parse" # HTML_TAG_PATTERN, POST_CHUNK_SPLIT_PATTERN, POST_ID_PATTERN 等を再利用

module X5ch
  module FivechBrowser
    # ExportPost はアーカイブ用途の完全な投稿データ。TUI/Discord/TTS用の Post とは別に、
    # 原文保持(body_raw)・派生表示(body_display)・返信関係・mail欄などを持つ。
    class ExportPost
      include JSON::Serializable

      @[JSON::Field(key: "external_id")]
      property external_id : String
      property num : Int32
      @[JSON::Field(key: "author_name_display")]
      property author_name_display : String
      @[JSON::Field(key: "mail_encoded", emit_null: false)]
      property mail_encoded : String?
      @[JSON::Field(key: "mail_decoded", emit_null: false)]
      property mail_decoded : String?
      @[JSON::Field(key: "user_id")]
      property user_id : String
      @[JSON::Field(key: "posted_at", emit_null: false)]
      property posted_at : String?
      @[JSON::Field(key: "posted_at_raw")]
      property posted_at_raw : String
      @[JSON::Field(key: "reply_to", emit_null: false)]
      property reply_to : Array(Int32)?
      @[JSON::Field(key: "body_raw")]
      property body_raw : String
      @[JSON::Field(key: "body_display")]
      property body_display : String
      @[JSON::Field(key: "body_html_original")]
      property body_html_original : String

      def initialize(
        @external_id : String,
        @num : Int32,
        @author_name_display : String,
        @mail_encoded : String?,
        @mail_decoded : String?,
        @user_id : String,
        @posted_at : String?,
        @posted_at_raw : String,
        @reply_to : Array(Int32)?,
        @body_raw : String,
        @body_display : String,
        @body_html_original : String,
      )
      end
    end

    # ExportThread はアーカイブ用途のスレッドメタデータ。
    class ExportThread
      include JSON::Serializable

      @[JSON::Field(key: "external_id")]
      property external_id : String
      property title : String
      @[JSON::Field(key: "board_name", emit_null: false)]
      property board_name : String?
      @[JSON::Field(key: "created_at", emit_null: false)]
      property created_at : String?
      @[JSON::Field(key: "post_count")]
      property post_count : Int32

      def initialize(@external_id, @title, @board_name, @created_at, @post_count)
      end
    end

    # ExportSource はスクレイピング元の情報。
    class ExportSource
      include JSON::Serializable

      property provider : String
      @[JSON::Field(key: "board_url")]
      property board_url : String
      @[JSON::Field(key: "dat_file")]
      property dat_file : String
      @[JSON::Field(key: "thread_url")]
      property thread_url : String
      @[JSON::Field(key: "scraped_at")]
      property scraped_at : String

      def initialize(@provider, @board_url, @dat_file, @thread_url, @scraped_at)
      end
    end

    # ExportResult は export サブコマンドが出力するJSON全体の構造。
    class ExportResult
      include JSON::Serializable

      property source : ExportSource
      property thread : ExportThread
      property posts : Array(ExportPost)

      def initialize(@source, @thread, @posts)
      end
    end

    MAIL_LINK_PATTERN     = /<a\s+[^>]*href="\/cdn-cgi\/l\/email-protection#([0-9a-fA-F]+)"[^>]*>(.*?)<\/a>/
    REPLY_LINK_TAG_PATTERN = /<a[^>]*class="reply_link"[^>]*>/
    HREF_NUM_PATTERN       = /href="[^"]*?\/(\d+)"/
    POSTED_AT_PATTERN      = /^(\d{4})\/(\d{2})\/(\d{2})\([月火水木金土日]\)\s+(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?/
    # Go版の (?s) = DOTALL。Crystalでは /m。
    LD_JSON_PATTERN = /<script\s+type="application\/ld\+json">(.*?)<\/script>/m

    # decode_cf_email はCloudflareのメール難読化(cdn-cgi/l/email-protection)をデコードする。
    # アルゴリズムはCloudflare公式仕様(先頭2桁がXORキー、残りを2桁ずつXOR)に基づく。
    def self.decode_cf_email(hex_str : String) : String?
      return nil if hex_str.size < 2 || hex_str.size.odd?

      key = hex_str[0, 2].to_u8?(16)
      return nil unless key

      bytes = Bytes.new((hex_str.size - 2) // 2)
      i = 2
      idx = 0
      while i < hex_str.size
        b = hex_str[i, 2].to_u8?(16)
        return nil unless b
        bytes[idx] = b ^ key
        i += 2
        idx += 1
      end
      String.new(bytes)
    end

    # extract_reply_to は本文HTML中の class="reply_link" アンカーから返信先レス番号を抽出する。
    # 本文中の引用符("&gt;...")など reply_link クラスを持たないものは対象外。
    def self.extract_reply_to(content_html : String) : Array(Int32)
      result = [] of Int32
      content_html.scan(REPLY_LINK_TAG_PATTERN) do |tag_match|
        tag = tag_match[0]
        if m = HREF_NUM_PATTERN.match(tag)
          if n = m[1].to_i?
            result << n
          end
        end
      end
      result
    end

    # parse_posted_at は "2025/12/16(火) 05:05:09.95" 形式をISO8601(元のオフセットのまま、Nano精度)に変換する。
    # パースできない場合はnilを返す(呼び出し側は posted_at_raw を代わりに使う)。
    def self.parse_posted_at(raw : String) : String?
      m = POSTED_AT_PATTERN.match(raw)
      return nil unless m

      year = m[1].to_i
      month = m[2].to_i
      day = m[3].to_i
      hour = m[4].to_i
      minute = m[5].to_i
      second = m[6].to_i

      nsec = 0
      if frac = m[7]?
        frac = frac.ljust(9, '0')[0, 9]
        nsec = frac.to_i
      end

      jst = Time::Location.fixed(9 * 3600)
      t =
        begin
          Time.local(year, month, day, hour, minute, second, nanosecond: nsec, location: jst)
        rescue ArgumentError
          return nil
        end

      format_rfc3339_nano(t)
    end

    # Time#to_rfc3339 は常にUTCへ変換してしまう(Go版の time.RFC3339Nano は元のオフセットを保つ)ため、
    # オフセット保持・末尾ゼロ切り詰めのフォーマットを自前で行う。
    def self.format_rfc3339_nano(t : Time) : String
      base = t.to_s("%Y-%m-%dT%H:%M:%S")
      ns = t.nanosecond
      frac = ""
      if ns > 0
        s = ns.to_s.rjust(9, '0').rstrip('0')
        frac = ".#{s}" unless s.empty?
      end
      off = t.offset
      sign = off < 0 ? "-" : "+"
      abs = off.abs
      oh = abs // 3600
      om = (abs % 3600) // 60
      "#{base}#{frac}#{sign}#{oh.to_s.rjust(2, '0')}:#{om.to_s.rjust(2, '0')}"
    end

    # extract_plain_text はタグを除去し、標準ライブラリでHTMLエンティティを正しくデコードする。
    # Ruby版由来の「&gt;/&lt;/&ampのみ手動置換」バグを修正したもの(h補完は行わない=原文のまま)。
    def self.extract_plain_text(inner_html : String) : String
      text = inner_html.gsub("<br>", "\n")
      text = text.gsub(HTML_TAG_PATTERN, " ")
      text = HTML.unescape(text)
      text.strip
    end

    # parse_posts_for_export はスレッドHTMLをアーカイブ用の完全な構造でパースする。
    # thread_external_id は "5ch:host/path/datnum" 形式で、各投稿の external_id 組み立てに使う。
    # Ruby版には存在しない、このプロジェクト独自の機能。
    def self.parse_posts_for_export(html : String, thread_external_id : String) : Array(ExportPost)
      chunks = html.split(POST_CHUNK_SPLIT_PATTERN)
      chunks = chunks.size > 0 ? chunks[1..] : chunks

      posts = [] of ExportPost

      chunks.each do |chunk|
        id_match = POST_ID_PATTERN.match(chunk)
        next unless id_match
        num = id_match[1].to_i

        author_display = "名無し"
        mail_encoded = nil.as(String?)
        mail_decoded = nil.as(String?)

        if m = POST_USERNAME_PATTERN.match(chunk)
          raw_name = m[1]
          if mm = MAIL_LINK_PATTERN.match(raw_name)
            mail_encoded = mm[1]
            author_display = mm[2].gsub(HTML_TAG_PATTERN, "").strip
            mail_decoded = decode_cf_email(mail_encoded)
          else
            author_display = raw_name.gsub(HTML_TAG_PATTERN, "").strip
          end
        end

        posted_at_raw = ""
        if m = POST_DATE_PATTERN.match(chunk)
          posted_at_raw = m[1].strip
        end

        user_id = ""
        if m = POST_UID_PATTERN.match(chunk)
          user_id = m[1].strip.lchop("ID:").strip
        end

        body_html = ""
        if m = POST_CONTENT_PATTERN.match(chunk)
          body_html = m[1]
        elsif m = POST_CONTENT_FALLBACK.match(chunk)
          body_html = m[1].gsub(TRAILING_DIV_PATTERN, "")
        end

        reply_to = extract_reply_to(body_html)
        body_raw = extract_plain_text(body_html)
        body_display = body_raw.gsub(H_RESTORE_PATTERN) { |m| "h#{m}" }

        posts << ExportPost.new(
          external_id: "#{thread_external_id}##{num}",
          num: num,
          author_name_display: author_display,
          mail_encoded: (mail_encoded && !mail_encoded.empty?) ? mail_encoded : nil,
          mail_decoded: (mail_decoded && !mail_decoded.empty?) ? mail_decoded : nil,
          user_id: user_id,
          posted_at: parse_posted_at(posted_at_raw),
          posted_at_raw: posted_at_raw,
          reply_to: reply_to.empty? ? nil : reply_to,
          body_raw: body_raw,
          body_display: body_display,
          body_html_original: body_html.strip,
        )
      end

      posts
    end

    # extract_board_name はページ全体のHTMLからJSON-LDパンくずリストの板名(position=2)を抽出する。
    # 抽出できなければ空文字を返す(1件のサンプルで確認した構造に基づく、実データが限定的な点に注意)。
    def self.extract_board_name(full_html : String) : String
      m = LD_JSON_PATTERN.match(full_html)
      return "" unless m

      raw_items =
        begin
          JSON.parse(m[1])
        rescue JSON::ParseException
          return ""
        end

      return "" unless raw_items.as_a?

      raw_items.as_a.each do |item|
        next unless item["@type"]?.try(&.as_s?) == "BreadcrumbList"
        elements = item["itemListElement"]?.try(&.as_a?)
        next unless elements
        elements.each do |el|
          position = el["position"]?.try(&.as_i?)
          name = el["name"]?.try(&.as_s?)
          return name if position == 2 && name
        end
      end

      ""
    rescue
      ""
    end

    # dat_timestamp_to_rfc3339 は dat ファイル名(スレ立て時刻のUNIXタイムスタンプ)をISO8601(UTC)に変換する。
    def self.dat_timestamp_to_rfc3339(dat_file : String) : String
      ts_str = dat_file.sub(/\.dat$/, "")
      ts = ts_str.to_i64?
      return "" unless ts
      Time.unix(ts).to_rfc3339
    end
  end
end
