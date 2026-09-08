require "../terminal/terminal"

module X5ch
  module Selector
    struct Item(T)
      property text : String
      property value : T

      def initialize(@text : String, @value : T)
      end
    end

    enum Action
      Selected
      Quit
      Back
      Reload
      Interrupt
    end

    struct Result(T)
      property action : Action
      property value : T?
      property page : Int32

      def initialize(@action : Action, @value : T? = nil, @page : Int32 = 0)
      end
    end

    class InterruptedError < Exception
    end

    # TermIO はコールバックに渡される、rawモードを維持したまま行入力・単キー入力を行うためのヘルパー。
    class TermIO
      def initialize(@key_ch : Channel(UInt8), @err_ch : Channel(Exception), @out : IO)
      end

      def print(s : String) : Nil
        @out.print(s)
        @out.flush
      end

      def println(s : String) : Nil
        print("#{s}\r\n")
      end

      # 1バイト読めるまでブロックする(タイムアウト無し)。
      def read_key : UInt8
        select
        when b = @key_ch.receive
          b
        when ex = @err_ch.receive
          raise ex
        end
      end

      # rawモードのまま、Enterまで1行を手動エコー・バックスペース処理しながら読む。
      def read_line : String
        buf = [] of Char
        loop do
          b = read_key
          case b
          when 0x0d, 0x0a
            print("\r\n")
            return buf.join
          when 0x7f, 0x08
            unless buf.empty?
              buf.pop
              print("\b \b")
            end
          when 0x03
            raise InterruptedError.new
          else
            ch = b.chr
            buf << ch
            print(ch.to_s)
          end
        end
      end
    end

    # Config は Run() の挙動を決める設定。個々のコールバックの有無で分岐を表現する(nilなら無効/no-op)。
    class Config(T)
      property title : String
      property items : Array(Item(T))
      property start_page : Int32 = 0
      property page_size : Int32 = 20

      property status_line : Proc(String)? = nil

      property search_label : String = ""
      property on_global_search : Proc(String, Bool)? = nil

      property supports_reload : Bool = false

      property help_text : String = ""

      property on_queue_manage : Proc(TermIO, Bool)? = nil
      property on_history_manage : Proc(TermIO, Bool)? = nil
      property on_history_delete_item : Proc(TermIO, Int32, Item(T), {Item(T), Bool})? = nil

      # can_enqueue は'm'キー押下時、番号入力プロンプトを出す前のチェック。
      # nilなら常に許可。falseなら {ok:false, msg} を返しメッセージ表示のみでプロンプトを出さない。
      property can_enqueue : Proc({Bool, String})? = nil
      property on_enqueue : Proc(TermIO, Int32, Item(T), {Item(T), Bool})? = nil

      def initialize(@title : String, @items : Array(Item(T)))
      end
    end

    def self.start_key_reader(io : IO) : {Channel(UInt8), Channel(Exception)}
      key_ch = Channel(UInt8).new
      err_ch = Channel(Exception).new(1)
      spawn do
        loop do
          byte = io.read_byte
          if byte.nil?
            err_ch.send(IO::EOFError.new)
            break
          end
          key_ch.send(byte)
        end
      rescue ex
        err_ch.send(ex)
      end
      {key_ch, err_ch}
    end

    # ページング・数字選択・検索・各種アクションキーを処理するメインループ。
    def self.run(input : IO, output : IO, fd : Int32, cfg : Config(T)) : Result(T) forall T
      return Result(T).new(Action::Back, nil, 0) if cfg.items.empty?

      page_size = cfg.page_size <= 0 ? 20 : cfg.page_size

      original_termios = X5ch::Terminal.enable_raw_mode(fd)

      begin
        key_ch, err_ch = start_key_reader(input)
        sio = TermIO.new(key_ch, err_ch, output)

        original_items = cfg.items
        filtered_items = cfg.items
        filter_keyword = ""
        input_buffer = ""
        current_page = cfg.start_page
        needs_full_redraw = true

        loop do
          total_pages = (filtered_items.size + page_size - 1) // page_size
          total_pages = 1 if total_pages < 1
          current_page = 0 if current_page >= total_pages
          current_page = total_pages - 1 if current_page < 0

          start_idx = current_page * page_size
          end_idx = Math.min(start_idx + page_size, filtered_items.size)
          view_items = filtered_items[start_idx...end_idx]

          display_title = cfg.title
          display_title += " (検索: #{filter_keyword})" unless filter_keyword.empty?
          status = cfg.status_line.try(&.call) || ""
          header_str = "--- #{display_title} (#{current_page + 1}/#{total_pages})#{status} ---"

          last_idx = Math.max(view_items.size - 1, 0)
          valid_range = "#{start_idx}-#{start_idx + last_idx}"

          search_label = cfg.search_label.empty? ? ",s" : ",s(#{cfg.search_label})"
          prompt_keys = "[#{valid_range},Enter,p,b#{search_label},h,q,t"
          if cfg.on_enqueue
            prompt_keys += ",r,m,H"
          elsif cfg.on_history_manage
            prompt_keys += ",H"
          end
          prompt_keys += "] > "

          if needs_full_redraw
            output.print("\e[H\e[2J")
            output.print("#{header_str}\r\n")
            view_items.each_with_index do |item, i|
              output.print("[#{start_idx + i}] #{item.text}\r\n")
            end
            output.print("#{prompt_keys}#{input_buffer}")
            output.flush
            needs_full_redraw = false
          else
            output.print("\e[H#{header_str}\e[K")
            prompt_row = view_items.size + 2
            output.print("\e[#{prompt_row};1H")
            output.print("#{prompt_keys}#{input_buffer}")
            output.flush
          end

          b = nil.as(UInt8?)
          read_err = nil.as(Exception?)
          select
          when byte = key_ch.receive
            b = byte
          when ex = err_ch.receive
            read_err = ex
          when timeout(1.seconds)
            next
          end

          raise read_err if read_err

          byte = b.not_nil!

          if byte == 0x03
            return Result(T).new(Action::Interrupt, nil, current_page)
          end

          if byte >= '0'.ord && byte <= '9'.ord
            input_buffer += byte.chr.to_s
            next
          end

          if byte == 0x0d || byte == 0x0a
            if input_buffer.empty?
              current_page += 1
            else
              idx = input_buffer.to_i?
              input_buffer = ""
              if idx && idx >= 0 && idx < filtered_items.size
                return Result(T).new(Action::Selected, filtered_items[idx].value, current_page)
              end
            end
            needs_full_redraw = true
            next
          end

          if byte == 0x7f || byte == 0x08
            input_buffer = input_buffer[0...-1] unless input_buffer.empty?
            next
          end

          input_buffer = ""

          case byte.chr
          when 'q'
            return Result(T).new(Action::Quit, nil, current_page)
          when 'b'
            return Result(T).new(Action::Back, nil, current_page)
          when 'r'
            needs_full_redraw = true
            if cfg.supports_reload
              return Result(T).new(Action::Reload, nil, current_page)
            end
          when 't'
            if (cb = cfg.on_queue_manage)
              if cb.call(sio)
                return Result(T).new(Action::Interrupt, nil, current_page)
              end
            end
            needs_full_redraw = true
          when 'H'
            if (cb = cfg.on_history_manage)
              if cb.call(sio)
                return Result(T).new(Action::Interrupt, nil, current_page)
              end
              needs_full_redraw = true
            elsif (cb = cfg.on_history_delete_item)
              sio.print("\r\n履歴を削除する番号を入力 > ")
              begin
                line = sio.read_line
                idx = line.strip.to_i?
                if idx && idx >= 0 && idx < filtered_items.size
                  updated, ok = cb.call(sio, idx, filtered_items[idx])
                  filtered_items[idx] = updated if ok
                end
              rescue InterruptedError
                return Result(T).new(Action::Interrupt, nil, current_page)
              end
              needs_full_redraw = true
            end
          when 'm'
            if (cb = cfg.on_enqueue)
              if (can_check = cfg.can_enqueue)
                ok, msg = can_check.call
                unless ok
                  sio.println("\r\n#{msg}")
                  sleep 1.seconds
                  needs_full_redraw = true
                  next
                end
              end
              sio.print("\r\n転送する番号を入力 > ")
              begin
                line = sio.read_line
                idx = line.strip.to_i?
                if idx && idx >= 0 && idx < filtered_items.size
                  updated, ok = cb.call(sio, idx, filtered_items[idx])
                  filtered_items[idx] = updated if ok
                end
              rescue InterruptedError
                return Result(T).new(Action::Interrupt, nil, current_page)
              end
              needs_full_redraw = true
            end
          when 'h'
            output.print("\e[H\e[2J")
            output.print(cfg.help_text)
            output.flush
            hb = sio.read_key
            return Result(T).new(Action::Interrupt, nil, current_page) if hb == 0x03
            needs_full_redraw = true
          when 's'
            sio.print("\r\n検索キーワード > ")
            keyword =
              begin
                sio.read_line
              rescue InterruptedError
                return Result(T).new(Action::Interrupt, nil, current_page)
              end
            if keyword.strip.empty?
              needs_full_redraw = true
              next
            end
            keyword = keyword.strip

            if (cb = cfg.on_global_search)
              if cb.call(keyword)
                return Result(T).new(Action::Interrupt, nil, current_page)
              end
              needs_full_redraw = true
            else
              filter_keyword = keyword
              new_filtered = original_items.select { |it| it.text.includes?(keyword) }
              current_page = 0
              if new_filtered.empty?
                sio.println("該当なし")
                sio.read_key
                filtered_items = original_items
                filter_keyword = ""
              else
                filtered_items = new_filtered
              end
              needs_full_redraw = true
            end
          when 'p'
            current_page -= 1
            needs_full_redraw = true
          end
        end
      ensure
        X5ch::Terminal.restore_mode(fd, original_termios)
      end
    end
  end
end
