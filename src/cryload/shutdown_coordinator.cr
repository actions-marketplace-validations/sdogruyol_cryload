module Cryload
  class ShutdownCoordinator
    # The report must be printed exactly once. Without this, a signal arriving
    # while the receive loop is already finishing produced two reports, and
    # under multiple threads the two writers could interleave mid-line.
    @@reported = Atomic(Int32).new(0)

    def self.finish : NoReturn
      claim_report
      Logger.log_progress
      Logger.log_final
      exit Cryload.stats.exit_code.value
    end

    # A run cut short still reports, and a breached threshold still outranks the
    # signal: CI cares more about "performance regressed" than about "someone
    # pressed Ctrl-C". v5 exited 0 here, so `timeout 60 cryload ...` looked
    # green no matter what.
    def self.finish_on_signal(reason : Process::ExitReason) : NoReturn
      signal_code = exit_code_for(reason)

      stats = Cryload.stats?
      unless stats
        exit signal_code.value
      end

      claim_report
      stats.mark_benchmark_end
      Logger.log_progress
      Logger.log_final(signal_code)

      run_code = stats.exit_code
      exit run_code.threshold_breach? ? run_code.value : signal_code.value
    end

    def self.exit_code_for(reason : Process::ExitReason) : ExitCode
      case reason
      when .interrupted? then ExitCode::Interrupted
      else                    ExitCode::Terminated
      end
    end

    private def self.claim_report : Nil
      _, claimed = @@reported.compare_and_set(0, 1)
      return if claimed

      # The other side owns the report and is about to exit the process; parking
      # here is cheaper than racing it to stdout.
      loop { sleep 1.second }
    end
  end
end
