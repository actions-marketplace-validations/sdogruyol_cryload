module Cryload
  enum ExitCode
    Ok                =   0
    ThresholdBreach   =   1
    ConfigError       =   2
    TargetUnreachable =   3
    Interrupted       = 130
    Terminated        = 143

    def reason : String
      case self
      in .ok?                 then "ok"
      in .threshold_breach?   then "threshold_breached"
      in .config_error?       then "config_error"
      in .target_unreachable? then "target_unreachable"
      in .interrupted?        then "interrupted"
      in .terminated?         then "terminated"
      end
    end
  end

  # A single configured gate. `scope` is nil for a run-wide gate and a URL
  # substring pattern for a per-endpoint one.
  struct Threshold
    enum Metric
      P50
      P75
      P90
      P95
      P99
      P999
      Avg
      MaxLatency
      FailRate
      Rps

      # Only latency metrics are affected by coordinated-omission correction;
      # a failure rate or a throughput figure has no send delay to add.
      def latency? : Bool
        !(fail_rate? || rps?)
      end

      def percentile : Float64?
        case self
        when .p50?  then 50.0
        when .p75?  then 75.0
        when .p90?  then 90.0
        when .p95?  then 95.0
        when .p99?  then 99.0
        when .p999? then 99.9
        end
      end

      def label : String
        case self
        in .p50?         then "p50"
        in .p75?         then "p75"
        in .p90?         then "p90"
        in .p95?         then "p95"
        in .p99?         then "p99"
        in .p999?        then "p999"
        in .avg?         then "avg"
        in .max_latency? then "max"
        in .fail_rate?   then "fail_rate_percent"
        in .rps?         then "requests_per_second"
        end
      end

      def flag : String
        rps? ? "min-rps" : "max-#{label_for_flag}"
      end

      private def label_for_flag : String
        case self
        when .avg?         then "avg"
        when .max_latency? then "latency"
        when .fail_rate?   then "fail-rate"
        else                    label
        end
      end
    end

    enum Comparator
      AtMost
      AtLeast

      def symbol : String
        at_most? ? "<=" : ">="
      end

      def satisfied?(actual : Float64, limit : Float64) : Bool
        at_most? ? actual <= limit : actual >= limit
      end
    end

    getter scope : String?
    getter metric : Metric
    getter limit : Float64

    def initialize(@metric : Metric, @limit : Float64, @scope : String? = nil)
    end

    def comparator : Comparator
      @metric.rps? ? Comparator::AtLeast : Comparator::AtMost
    end

    def name : String
      @metric.flag
    end
  end

  # Outcome of evaluating one threshold, reported verbatim in JSON and as a
  # PASS/FAIL line in the text report.
  struct ThresholdResult
    getter name : String
    getter scope : String
    getter metric : String
    getter comparator : String
    getter limit : Float64
    getter actual : Float64
    getter? passed : Bool

    def initialize(@name, @scope, @metric, @comparator, @limit, @actual, @passed)
    end
  end

  struct CiThresholds
    # A run that lands within 1% of the requested rate counts as attained;
    # scheduling jitter alone can cost a fraction of a percent.
    RATE_ATTAINMENT_TOLERANCE = 99.0

    property? fail_on_error : Bool
    property? fail_on_transport_error : Bool
    property? fail_on_rate_miss : Bool
    getter thresholds : Array(Threshold)

    def initialize(
      @fail_on_error : Bool = false,
      @fail_on_transport_error : Bool = false,
      @fail_on_rate_miss : Bool = false,
      @thresholds : Array(Threshold) = [] of Threshold,
    )
    end

    def global : Array(Threshold)
      @thresholds.select { |threshold| threshold.scope.nil? }
    end

    def scoped : Array(Threshold)
      @thresholds.reject { |threshold| threshold.scope.nil? }
    end

    def any? : Bool
      !@thresholds.empty? || @fail_on_error || @fail_on_transport_error || @fail_on_rate_miss
    end

    def scoped? : Bool
      @thresholds.any?(&.scope)
    end
  end
end
