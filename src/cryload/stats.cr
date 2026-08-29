module Cryload
  # Immutable description of the run, carried into the report so a JSON artifact
  # is self-describing.
  struct RunConfig
    getter workers : Int32
    getter connections : Int32
    getter rate_limit : Float64?
    getter? latency_correction : Bool
    getter? keepalive : Bool
    getter timeout : Time::Span?
    getter request_timeout : Time::Span?
    getter duration : Time::Span?
    getter warmup : Time::Span?
    getter request_number : Int32?

    def initialize(
      @workers : Int32 = 1,
      @connections : Int32 = 10,
      @rate_limit : Float64? = nil,
      @latency_correction : Bool = true,
      @keepalive : Bool = true,
      @timeout : Time::Span? = nil,
      @request_timeout : Time::Span? = nil,
      @duration : Time::Span? = nil,
      @warmup : Time::Span? = nil,
      @request_number : Int32? = nil,
    )
    end
  end

  # Stats holder for the benchmark.
  class Stats
    # Per-URL histograms are bounded: a cache-busting list of tens of thousands
    # of URLs would spend more memory on the breakdown than the run is worth,
    # and per-URL percentiles over a handful of samples each are meaningless.
    PER_URL_LIMIT = 1000

    # One completed response, moved from a worker into its batch. A struct so
    # the hot path stays allocation-free.
    struct Sample
      getter url_index : Int32
      getter status_code : Int32
      getter total_ms : Float64
      getter corrected_ms : Float64
      getter send_delay_ms : Float64
      getter ttfb_ms : Float64
      getter response_bytes : Int64
      getter dns_ms : Float64?
      getter connect_ms : Float64?
      getter tls_ms : Float64?

      def initialize(
        @url_index : Int32,
        @status_code : Int32,
        @total_ms : Float64,
        @corrected_ms : Float64,
        @send_delay_ms : Float64,
        @ttfb_ms : Float64,
        @response_bytes : Int64,
        @dns_ms : Float64? = nil,
        @connect_ms : Float64? = nil,
        @tls_ms : Float64? = nil,
      )
      end
    end

    # Worker-local per-URL slice.
    class UrlBatch
      property requests = 0_i64
      property responses = 0_i64
      property transport_errors = 0_i64
      property ok = 0_i64
      property failed = 0_i64
      getter latency = Histogram::Sparse.new
    end

    # Global per-URL slice.
    class UrlStats
      property requests = 0_i64
      property responses = 0_i64
      property transport_errors = 0_i64
      property ok = 0_i64
      property failed = 0_i64
      getter latency = Histogram::Dense.new

      def merge(batch : UrlBatch) : Nil
        @requests += batch.requests
        @responses += batch.responses
        @transport_errors += batch.transport_errors
        @ok += batch.ok
        @failed += batch.failed
        @latency.merge batch.latency
      end

      def failure_rate_percent : Float64
        return 0.0 if @requests == 0
        ((@failed + @transport_errors).to_f / @requests) * 100.0
      end
    end

    # Worker-local stats batch flushed periodically to the global collector.
    class Batch
      getter total_request_count = 0_i64
      getter response_count = 0_i64
      getter total_response_bytes = 0_i64
      getter ok_requests = 0_i64
      getter not_ok_requests = 0_i64
      getter transport_error_count = 0_i64
      getter latency = Histogram::Sparse.new
      getter corrected_latency = Histogram::Sparse.new
      getter send_delay = Histogram::Sparse.new
      getter ttfb = Histogram::Sparse.new
      getter dns = Histogram::Sparse.new
      getter connect = Histogram::Sparse.new
      getter tls = Histogram::Sparse.new
      getter status_latency = Hash(Int32, Histogram::Sparse).new
      getter error_counts = Hash(String, Int64).new(0_i64)
      getter error_messages = Hash(String, String).new
      getter url_stats = Hash(Int32, UrlBatch).new

      def initialize(@success_status_ranges : Array(Range(Int32, Int32)) = [200..299], @track_urls : Bool = false)
      end

      def empty? : Bool
        @total_request_count == 0
      end

      def record(sample : Sample) : Nil
        @total_request_count += 1
        @response_count += 1
        @total_response_bytes += sample.response_bytes

        success = success_status?(sample.status_code)
        if success
          @ok_requests += 1
        else
          @not_ok_requests += 1
        end

        @latency.record sample.total_ms
        @corrected_latency.record sample.corrected_ms
        @send_delay.record sample.send_delay_ms
        @ttfb.record sample.ttfb_ms
        sample.dns_ms.try { |value| @dns.record value }
        sample.connect_ms.try { |value| @connect.record value }
        sample.tls_ms.try { |value| @tls.record value }

        status_histogram(sample.status_code).record sample.total_ms

        if @track_urls
          url = url_batch(sample.url_index)
          url.requests += 1
          url.responses += 1
          success ? (url.ok += 1) : (url.failed += 1)
          # Per-URL latency follows --latency-correction so per-endpoint gates
          # see the same outages the global ones do.
          url.latency.record latency_correction? ? sample.corrected_ms : sample.total_ms
        end
      end

      # Transport errors are excluded from latency metrics: connect failures
      # (~0 ms) and timeouts would otherwise skew the percentiles.
      def record_error(url_index : Int32, category : String, message : String?) : Nil
        @total_request_count += 1
        @transport_error_count += 1
        @error_counts[category] += 1
        if message && !@error_messages.has_key?(category)
          @error_messages[category] = message.byte_slice(0, {message.bytesize, 200}.min)
        end

        if @track_urls
          url = url_batch(url_index)
          url.requests += 1
          url.transport_errors += 1
        end
      end

      # Set once by the load generator; the batch needs it to pick which latency
      # feeds the per-URL histogram.
      property? latency_correction : Bool = true

      private def status_histogram(status_code : Int32) : Histogram::Sparse
        @status_latency[status_code] ||= Histogram::Sparse.new
      end

      private def url_batch(url_index : Int32) : UrlBatch
        @url_stats[url_index] ||= UrlBatch.new
      end

      private def success_status?(status_code : Int32) : Bool
        @success_status_ranges.any?(&.includes?(status_code))
      end
    end

    @benchmark_end : Time::Instant?

    getter request_number : Int32
    getter? duration_mode : Bool
    getter benchmark_start : Time::Instant
    getter url : String
    getter urls : Array(URI)
    getter output_format : String
    getter success_status_ranges : Array(Range(Int32, Int32))
    getter ci_thresholds : CiThresholds
    getter config : RunConfig
    getter? progress_enabled : Bool
    getter? track_urls : Bool

    def initialize(
      @request_number : Int32,
      @duration_mode : Bool = false,
      @benchmark_start : Time::Instant = Time.instant,
      @url : String = "",
      @output_format : String = "text",
      @success_status_ranges : Array(Range(Int32, Int32)) = [200..299],
      @ci_thresholds : CiThresholds = CiThresholds.new,
      @progress_enabled : Bool = false,
      @config : RunConfig = RunConfig.new,
      @urls : Array(URI) = [] of URI,
    )
      @total_request_count = 0_i64
      @response_count = 0_i64
      @total_response_bytes = 0_i64
      @ok_requests = 0_i64
      @not_ok_requests = 0_i64
      @transport_error_count = 0_i64
      @latency = Histogram::Dense.new
      @corrected_latency = Histogram::Dense.new
      @send_delay = Histogram::Dense.new
      @ttfb = Histogram::Dense.new
      @dns = Histogram::Dense.new
      @connect = Histogram::Dense.new
      @tls = Histogram::Dense.new
      @status_latency = Hash(Int32, Histogram::Dense).new
      @error_counts = Hash(String, Int64).new(0_i64)
      @error_messages = Hash(String, String).new
      @url_stats = Hash(Int32, UrlStats).new
      @mutex = Mutex.new
      @benchmark_end = nil
      # Per-URL detail is worth collecting for a multi-URL run, and for a
      # single-URL run only when a per-endpoint gate needs it.
      @track_urls = @urls.size <= PER_URL_LIMIT && (@urls.size > 1 || @ci_thresholds.scoped?)
    end

    def new_batch : Batch
      batch = Batch.new(@success_status_ranges, @track_urls)
      batch.latency_correction = @config.latency_correction?
      batch
    end

    def merge_batch(batch : Batch) : Nil
      return if batch.empty?

      @mutex.synchronize { merge_batch_without_lock batch }
    end

    def record(sample : Sample) : Nil
      batch = new_batch
      batch.record sample
      merge_batch batch
    end

    def record_error(category : String, message : String? = nil, url_index : Int32 = 0) : Nil
      batch = new_batch
      batch.record_error url_index, category, message
      merge_batch batch
    end

    private def merge_batch_without_lock(batch : Batch) : Nil
      @total_request_count += batch.total_request_count
      @response_count += batch.response_count
      @total_response_bytes += batch.total_response_bytes
      @ok_requests += batch.ok_requests
      @not_ok_requests += batch.not_ok_requests
      @transport_error_count += batch.transport_error_count

      @latency.merge batch.latency
      @corrected_latency.merge batch.corrected_latency
      @send_delay.merge batch.send_delay
      @ttfb.merge batch.ttfb
      @dns.merge batch.dns
      @connect.merge batch.connect
      @tls.merge batch.tls

      batch.status_latency.each do |status_code, histogram|
        (@status_latency[status_code] ||= Histogram::Dense.new).merge histogram
      end

      batch.error_counts.each do |category, count|
        @error_counts[category] += count
      end
      batch.error_messages.each do |category, message|
        @error_messages[category] ||= message
      end

      batch.url_stats.each do |url_index, url_batch|
        (@url_stats[url_index] ||= UrlStats.new).merge url_batch
      end
    end

    # Timing window ------------------------------------------------------------

    # Warmup runs before the timed window; v5 started the clock before warmup,
    # which deflated throughput and shortened the duration window by the warmup
    # length.
    def start_benchmark_window : Nil
      @mutex.synchronize { @benchmark_start = Time.instant }
    end

    def mark_benchmark_end(at : Time::Instant = Time.instant) : Nil
      @mutex.synchronize { @benchmark_end ||= at }
    end

    def wall_clock_seconds : Float64
      @mutex.synchronize do
        end_at = @benchmark_end || Time.instant
        (end_at - @benchmark_start).total_seconds
      end
    end

    def deadline : Time::Instant?
      @config.duration.try { |span| benchmark_start + span }
    end

    # Counters ----------------------------------------------------------------

    def total_request_count : Int64
      @mutex.synchronize { @total_request_count }
    end

    def response_count : Int64
      @mutex.synchronize { @response_count }
    end

    def transport_error_count : Int64
      @mutex.synchronize { @transport_error_count }
    end

    def ok_requests : Int64
      @mutex.synchronize { @ok_requests }
    end

    def not_ok_requests : Int64
      @mutex.synchronize { @not_ok_requests }
    end

    def total_response_bytes : Int64
      @mutex.synchronize { @total_response_bytes }
    end

    def empty? : Bool
      total_request_count == 0
    end

    def request_per_second : Float64
      count = total_request_count
      return 0.0 if count == 0
      elapsed = wall_clock_seconds
      elapsed > 0 ? count / elapsed : 0.0
    end

    def bytes_per_second : Float64
      bytes = total_response_bytes
      return 0.0 if bytes == 0
      elapsed = wall_clock_seconds
      elapsed > 0 ? bytes / elapsed : 0.0
    end

    def average_bytes_per_response : Float64
      @mutex.synchronize do
        @response_count == 0 ? 0.0 : @total_response_bytes.to_f / @response_count
      end
    end

    def failure_rate_percent : Float64
      @mutex.synchronize { failure_rate_percent_unlocked }
    end

    # Latency views -----------------------------------------------------------

    # Snapshot of one histogram taken under the lock, so the report never mixes
    # values from different instants.
    struct LatencyView
      getter count : Int64
      getter avg : Float64
      getter min : Float64
      getter max : Float64
      getter stdev : Float64
      getter percentiles : Hash(Float64, Float64)

      def initialize(@count, @avg, @min, @max, @stdev, @percentiles)
      end

      def p(value : Float64) : Float64
        @percentiles[value]
      end

      def empty? : Bool
        @count == 0
      end
    end

    REPORT_PERCENTILES = [10.0, 25.0, 50.0, 75.0, 90.0, 95.0, 99.0, 99.9]
    PHASE_PERCENTILES  = [50.0, 90.0, 95.0, 99.0, 99.9]

    def latency_view : LatencyView
      @mutex.synchronize { view_of @latency, REPORT_PERCENTILES }
    end

    def corrected_latency_view : LatencyView
      @mutex.synchronize { view_of @corrected_latency, REPORT_PERCENTILES }
    end

    def send_delay_view : LatencyView
      @mutex.synchronize { view_of @send_delay, PHASE_PERCENTILES }
    end

    # The histogram the CI gates read: corrected unless the user turned
    # correction off. Identical to the service histogram without --rate.
    def effective_latency_view : LatencyView
      @config.latency_correction? ? corrected_latency_view : latency_view
    end

    def phase_views : Hash(String, LatencyView)
      @mutex.synchronize do
        {
          "dns"     => view_of(@dns, PHASE_PERCENTILES),
          "connect" => view_of(@connect, PHASE_PERCENTILES),
          "tls"     => view_of(@tls, PHASE_PERCENTILES),
          "ttfb"    => view_of(@ttfb, PHASE_PERCENTILES),
          "total"   => view_of(@latency, PHASE_PERCENTILES),
        }
      end
    end

    def latency_histogram_bins(bin_count : Int32 = 11)
      @mutex.synchronize { @latency.linear_bins bin_count }
    end

    private def view_of(histogram : Histogram::Dense, percentiles : Array(Float64)) : LatencyView
      values = Hash(Float64, Float64).new
      percentiles.each { |percentile| values[percentile] = histogram.percentile(percentile) }
      LatencyView.new(
        histogram.count,
        histogram.avg,
        histogram.minimum,
        histogram.maximum,
        histogram.stdev,
        values,
      )
    end

    # Breakdowns --------------------------------------------------------------

    struct StatusEntry
      getter code : Int32
      getter count : Int64
      getter percent : Float64
      getter avg_ms : Float64
      getter p50_ms : Float64
      getter p95_ms : Float64
      getter p99_ms : Float64

      def initialize(@code, @count, @percent, @avg_ms, @p50_ms, @p95_ms, @p99_ms)
      end
    end

    struct ErrorEntry
      getter category : String
      getter count : Int64
      getter percent : Float64
      getter sample_message : String?

      def initialize(@category, @count, @percent, @sample_message)
      end
    end

    struct UrlEntry
      getter url : String
      getter requests : Int64
      getter responses : Int64
      getter transport_errors : Int64
      getter ok : Int64
      getter failed : Int64
      getter failure_rate_percent : Float64
      getter requests_per_second : Float64
      getter avg_ms : Float64
      getter min_ms : Float64
      getter max_ms : Float64
      getter p50_ms : Float64
      getter p75_ms : Float64
      getter p90_ms : Float64
      getter p95_ms : Float64
      getter p99_ms : Float64
      getter p999_ms : Float64

      def initialize(
        @url, @requests, @responses, @transport_errors, @ok, @failed,
        @failure_rate_percent, @requests_per_second, @avg_ms, @min_ms, @max_ms,
        @p50_ms, @p75_ms, @p90_ms, @p95_ms, @p99_ms, @p999_ms,
      )
      end
    end

    def status_breakdown : Array(StatusEntry)
      @mutex.synchronize do
        @status_latency.map do |status_code, histogram|
          StatusEntry.new(
            status_code,
            histogram.count,
            percent_of(histogram.count, @response_count),
            histogram.avg.round(2),
            histogram.percentile(50.0).round(2),
            histogram.percentile(95.0).round(2),
            histogram.percentile(99.0).round(2),
          )
        end.sort_by! { |entry| {-entry.count, entry.code} }
      end
    end

    def status_code_counts : Hash(Int32, Int64)
      @mutex.synchronize do
        counts = Hash(Int32, Int64).new(0_i64)
        @status_latency.each { |status_code, histogram| counts[status_code] = histogram.count }
        counts
      end
    end

    def error_breakdown : Array(ErrorEntry)
      @mutex.synchronize do
        total = @transport_error_count
        @error_counts.map do |category, count|
          ErrorEntry.new(category, count, percent_of(count, total), @error_messages[category]?)
        end.sort_by! { |entry| {-entry.count, entry.category} }
      end
    end

    def url_breakdown : Array(UrlEntry)?
      return unless @track_urls

      elapsed = wall_clock_seconds
      @mutex.synchronize do
        @url_stats.keys.sort!.map do |url_index|
          stats = @url_stats[url_index]
          latency = stats.latency
          UrlEntry.new(
            @urls[url_index]?.try(&.to_s) || @url,
            stats.requests,
            stats.responses,
            stats.transport_errors,
            stats.ok,
            stats.failed,
            stats.failure_rate_percent.round(2),
            (elapsed > 0 ? stats.requests / elapsed : 0.0).round(2),
            latency.avg.round(2),
            latency.minimum.round(2),
            latency.maximum.round(2),
            latency.percentile(50.0).round(2),
            latency.percentile(75.0).round(2),
            latency.percentile(90.0).round(2),
            latency.percentile(95.0).round(2),
            latency.percentile(99.0).round(2),
            latency.percentile(99.9).round(2),
          )
        end
      end
    end

    # Rate attainment ---------------------------------------------------------

    struct RateReport
      getter requested : Float64?
      getter attained : Float64
      getter attainment_percent : Float64?
      getter scheduled_requests : Int64?
      getter skipped_requests : Int64?
      getter schedule_drift_ms : Float64?

      def initialize(@requested, @attained, @attainment_percent, @scheduled_requests, @skipped_requests, @schedule_drift_ms)
      end

      def limited? : Bool
        !@requested.nil?
      end

      def missed?(tolerance : Float64) : Bool
        percent = @attainment_percent
        return false unless percent
        percent < tolerance
      end
    end

    def rate_report : RateReport
      attained = request_per_second
      requested = @config.rate_limit
      return RateReport.new(nil, attained, nil, nil, nil, nil) unless requested

      scheduled = scheduled_request_count(requested)
      issued = total_request_count
      skipped = scheduled ? {scheduled - issued, 0_i64}.max : nil
      drift = @mutex.synchronize { @send_delay.maximum }

      RateReport.new(
        requested,
        attained,
        ((attained / requested) * 100.0),
        scheduled,
        skipped,
        drift,
      )
    end

    # In duration mode the schedule is defined by the window; in request-count
    # mode the target itself is the schedule.
    private def scheduled_request_count(requested : Float64) : Int64?
      if duration = @config.duration
        RateLimiter.scheduled_count(requested, duration)
      elsif @request_number > 0
        @request_number.to_i64
      end
    end

    # Verdict -----------------------------------------------------------------

    def threshold_results : Array(ThresholdResult)
      results = [] of ThresholdResult
      latency = effective_latency_view
      metric_prefix = @config.latency_correction? ? "corrected_" : ""

      @ci_thresholds.global.each do |threshold|
        actual = global_metric_value threshold.metric, latency
        results << build_result(threshold, "global", actual, metric_prefix)
      end

      scoped = @ci_thresholds.scoped
      unless scoped.empty?
        breakdown = url_breakdown
        scoped.each do |threshold|
          scope = threshold.scope.to_s
          actual = 0.0
          if breakdown
            matching = breakdown.select(&.url.includes?(scope))
            # Worst value across every URL matching the pattern, so one slow
            # endpoint cannot hide behind a fast sibling.
            actual = aggregate_url_metric(threshold, matching) unless matching.empty?
          end
          results << build_result(threshold, scope, actual, metric_prefix)
        end
      end

      results
    end

    private def build_result(threshold : Threshold, scope : String, actual : Float64, metric_prefix : String) : ThresholdResult
      metric = threshold.metric.latency? ? "#{metric_prefix}#{threshold.metric.label}" : threshold.metric.label
      ThresholdResult.new(
        threshold.name,
        scope,
        metric,
        threshold.comparator.symbol,
        threshold.limit,
        actual.round(2),
        threshold.comparator.satisfied?(actual, threshold.limit),
      )
    end

    private def global_metric_value(metric : Threshold::Metric, latency : LatencyView) : Float64
      if percentile = metric.percentile
        return latency.p(percentile)
      end

      case metric
      when .avg?         then latency.avg
      when .max_latency? then latency.max
      when .fail_rate?   then failure_rate_percent
      when .rps?         then request_per_second
      else                    0.0
      end
    end

    # Worst value across every URL matching the pattern, evaluated on the same
    # latency the global gates use (see Batch#record).
    private def aggregate_url_metric(threshold : Threshold, entries : Array(UrlEntry)) : Float64
      values = entries.map do |entry|
        case threshold.metric
        in .p50?         then entry.p50_ms
        in .p75?         then entry.p75_ms
        in .p90?         then entry.p90_ms
        in .p95?         then entry.p95_ms
        in .p99?         then entry.p99_ms
        in .p999?        then entry.p999_ms
        in .avg?         then entry.avg_ms
        in .max_latency? then entry.max_ms
        in .fail_rate?   then entry.failure_rate_percent
        in .rps?         then entry.requests_per_second
        end
      end

      threshold.comparator.at_most? ? values.max : values.min
    end

    def breached_thresholds : Array(ThresholdResult)
      threshold_results.reject(&.passed?)
    end

    def exit_code : ExitCode
      return ExitCode::TargetUnreachable if target_unreachable?
      return ExitCode::ThresholdBreach if failure_flags_breached? || !breached_thresholds.empty?
      ExitCode::Ok
    end

    def target_unreachable? : Bool
      @mutex.synchronize { @response_count == 0 && @transport_error_count > 0 }
    end

    def failure_flags_breached? : Bool
      return true if @ci_thresholds.fail_on_transport_error? && transport_error_count > 0
      return true if @ci_thresholds.fail_on_error? && (not_ok_requests > 0 || transport_error_count > 0)
      if @ci_thresholds.fail_on_rate_miss?
        return true if rate_report.missed?(CiThresholds::RATE_ATTAINMENT_TOLERANCE)
      end
      false
    end

    # Output format helpers ---------------------------------------------------

    def json_output? : Bool
      @output_format == "json"
    end

    def csv_output? : Bool
      @output_format == "csv"
    end

    def quiet_output? : Bool
      @output_format == "quiet"
    end

    def text_output? : Bool
      @output_format == "text"
    end

    private def failure_rate_percent_unlocked : Float64
      return 0.0 if @total_request_count == 0
      ((@not_ok_requests + @transport_error_count).to_f / @total_request_count) * 100.0
    end

    private def percent_of(count : Int64, total : Int64) : Float64
      return 0.0 if total == 0
      ((count.to_f / total) * 100.0).round(2)
    end
  end

  def self.create_stats(
    request_number,
    duration_mode : Bool = false,
    benchmark_start : Time::Instant = Time.instant,
    url : String = "",
    output_format : String = "text",
    success_status_ranges : Array(Range(Int32, Int32)) = [200..299],
    ci_thresholds : CiThresholds = CiThresholds.new,
    progress_enabled : Bool = false,
    config : RunConfig = RunConfig.new,
    urls : Array(URI) = [] of URI,
  )
    @@stats = Stats.new(
      request_number, duration_mode, benchmark_start, url, output_format,
      success_status_ranges, ci_thresholds, progress_enabled, config, urls
    )
  end

  def self.stats : Stats
    stats = @@stats
    raise "Stats not initialized" unless stats
    stats
  end

  # Nil until the run is configured, so the signal handler can fire before the
  # load generator exists without blowing up.
  def self.stats? : Stats?
    @@stats
  end
end
