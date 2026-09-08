require "./types"

module X5ch
  module FivechBrowser
    # HTMLタグ除去用パターン。search.go/export.go でも共有される想定なのでここで公開定数化。
    HTML_TAG_PATTERN = /<[^>]+>/

    POST_CHUNK_SPLIT_PATTERN = /<div\s+[^>]*class=["'][^"']*clear post[^"']*["'][^>]*>/

    POST_ID_PATTERN       = /<span\s+class="postid">(\d+)<\/span>/
    # Crystalの正規表現リテラルの `m` 修飾子はGoの `(?s)` と同じ「.が改行にもマッチする」意味
    # (RubyのOnigmo由来。多くの言語の「複数行モード」とは異なる点に注意)。
    POST_USERNAME_PATTERN = /<span\s+class="postusername">(.+?)<\/span>/m
    POST_DATE_PATTERN     = /<span\s+class="date">(.+?)<\/span>/
    POST_UID_PATTERN      = /<span\s+class="uid">(.+?)<\/span>/
    POST_CONTENT_PATTERN  = /<div\s+class="post-content">(.*?)<\/div>/m
    POST_CONTENT_FALLBACK = /<div\s+class="post-content">(.*)/m
    TRAILING_DIV_PATTERN  = /<\/div>\s*$/

    # 5chの「アンチリンク」表記("http://"の先頭hを1文字落として"ttp://"にする慣習)の復元。
    #
    # 原典Ruby版の `/(^|[^h])(tps?:\/\/)/` にはバグがあり、"http://"のような
    # 既に正しい文字列まで壊してしまう("hthtp://"になる)ことを実測で確認した。
    # Go版はこれを負の後読み `(?<!h)(ttps?://)` に書き直して修正しており、
    # Crystal版も標準の Regex(PCRE) でこの正しい方を踏襲する。
    H_RESTORE_PATTERN = /(?<!h)(ttps?:\/\/)/

    def self.parse_posts(html : String) : Array(Post)
      chunks = html.split(POST_CHUNK_SPLIT_PATTERN)
      chunks = chunks.size > 0 ? chunks[1..] : chunks

      posts = [] of Post

      chunks.each do |chunk|
        id_match = POST_ID_PATTERN.match(chunk)
        next unless id_match
        num = id_match[1].to_i

        name = "名無し"
        if m = POST_USERNAME_PATTERN.match(chunk)
          name = m[1].gsub(HTML_TAG_PATTERN, "").strip
        end

        date = ""
        if m = POST_DATE_PATTERN.match(chunk)
          date = m[1].strip
        end
        uid = ""
        if m = POST_UID_PATTERN.match(chunk)
          uid = m[1].strip
        end
        date = "#{date} #{uid}"

        message = ""
        if m = POST_CONTENT_PATTERN.match(chunk)
          message = m[1]
        elsif m = POST_CONTENT_FALLBACK.match(chunk)
          message = m[1].gsub(TRAILING_DIV_PATTERN, "")
        end

        raw_msg = message
        raw_msg = raw_msg.gsub("<br>", "\n")
        raw_msg = raw_msg.gsub(HTML_TAG_PATTERN, " ")
        raw_msg = raw_msg.gsub("&gt;", ">")
        raw_msg = raw_msg.gsub("&lt;", "<")
        raw_msg = raw_msg.gsub("&amp;", "&")
        raw_msg = raw_msg.strip

        clean_message = raw_msg.gsub(H_RESTORE_PATTERN) { |m| "h#{m}" }

        posts << Post.new(num: num, name: name, date: date, message: clean_message)
      end

      posts
    end
  end
end
