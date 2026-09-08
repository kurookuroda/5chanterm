module X5ch
  module Cmd
    class LockError < Exception
    end

    # acquire_lock_with_handoff は多重起動を防ぐためのファイルロックを取得する。
    # 既にロックが取られている場合(=cronプロセスが稼働中)、PIDファイルからそのプロセスを
    # TERM→(5秒待機)→KILLの順で停止させてからロックを取得し直す。
    def self.acquire_lock_with_handoff(lock_path : String, pid_path : String) : File
      lock_file =
        begin
          File.open(lock_path, "a+")
        rescue ex
          raise LockError.new("ロックファイルを開けません: #{ex.message}")
        end

      begin
        lock_file.flock_exclusive(blocking: false)
        return lock_file # 即座に取得できた(通常ケース)
      rescue IO::Error
      end

      puts "\e[33m[Notice] バックグラウンドで転送プロセス(Cron)が稼働中です。\e[0m"

      pid = read_pid(pid_path)
      if pid && pid > 0
        print "プロセス(PID: #{pid})を停止し、処理を引き継ぎます..."

        begin
          Process.signal(Signal::TERM, pid)
        rescue
        end

        5.times do
          sleep 1.seconds
          break unless process_alive?(pid)
          print "."
        end

        if process_alive?(pid)
          print " 応答がないため強制終了します(KILL)..."
          begin
            Process.signal(Signal::KILL, pid)
          rescue
          end
        end
      end

      print " ロック取得..."
      begin
        lock_file.flock_exclusive(blocking: true)
      rescue ex
        raise LockError.new("ロック取得に失敗しました: #{ex.message}")
      end
      puts " 完了。\n\e[32m>> 処理を引き継いで起動します。\e[0m"
      sleep 1.seconds

      lock_file
    end

    def self.read_pid(pid_path : String) : Int64?
      return nil unless File.exists?(pid_path)
      body = File.read(pid_path)
      body.strip.to_i64?
    end

    # process_alive? はシグナル0を送ってプロセスの生存を確認する(実際にはシグナルを送らない)。
    def self.process_alive?(pid : Int64) : Bool
      Process.exists?(pid)
    end

    def self.write_pid(pid_path : String) : Nil
      File.write(pid_path, Process.pid.to_s)
    end

    def self.remove_pid(pid_path : String) : Nil
      File.delete(pid_path) if File.exists?(pid_path)
    rescue
    end
  end
end
