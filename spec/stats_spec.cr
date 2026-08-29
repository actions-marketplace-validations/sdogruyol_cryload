require "./spec_helper"

module StatsSpecHelper
  extend self

  def sample(
    total_ms : Float64,
    status : Int32 = 200,
    bytes : Int64 = 0_i64,
    url_index : Int32 = 0,
    corrected_ms : Float64? = nil,
    send_delay_ms : Float64 = 0.0,
    ttfb_ms : Float64? = nil,
    dns_ms : Float64? = nil,
    connect_ms : Float64? = nil,
    tls_ms : Float64? = nil,
  ) : Cryload::Stats::Sample
    Cryload::Stats::Sample.new(
      url_index: url_index,
      status_code: status,
      total_ms: total_ms,
      corrected_ms: corrected_ms || total_ms,
      send_delay_ms: send_delay_ms,
      ttfb_ms: ttfb_ms || total_ms,
      response_bytes: bytes,
      dns_ms: dns_ms,
      connect_ms: connect_ms,
      tls_ms: tls_ms,
    )
  end

  def stats(
    request_number : Int32 = 10,
    thresholds : Cryload::CiThresholds = Cryload::CiThresholds.new,
    config : Cryload::RunConfig = Cryload::RunConfig.new,
    urls : Array(URI) = [] of URI,
    success_status_ranges : Array(Range(Int32, Int32)) = [200..299],
    duration_mode : Bool = false,
    benchmark_start : Time::Instant = Time.instant,
  ) : Cryload::Stats
    Cryload::Stats.new(
      request_number,
      duration_mode: duration_mode,
      benchmark_start: benchmark_start,
      url: "http://example.test/run",
      success_status_ranges: success_status_ranges,
      ci_thresholds: thresholds,
      config: config,
      urls: urls,
    )
  end

  def threshold(metric : Cryload::Threshold::Metric, limit : Float64, scope : String? = nil)
    Cryload::Threshold.new(metric, limit, scope)
  end
end

describe Cryload::Stats do
  it "starts empty with zeroed metrics" do
    stats = StatsSpecHelper.stats

    stats.empty?.should be_true
    stats.total_request_count.should eq(0)
    stats.ok_requests.should eq(0)
    stats.not_ok_requests.should eq(0)

    view = stats.latency_view
    view.avg.should eq(0.0)
    view.min.should eq(0.0)
    view.max.should eq(0.0)
    view.stdev.should eq(0.0)
    view.p(95.0).should eq(0.0)
    view.p(99.0).should eq(0.0)
  end

  it "updates aggregate counters and latency stats" do
    stats = StatsSpecHelper.stats

    stats.record StatsSpecHelper.sample(10.0, 200, 100_i64)
    stats.record StatsSpecHelper.sample(20.0, 404, 50_i64)
    stats.record StatsSpecHelper.sample(30.0, 201, 150_i64)

    stats.empty?.should be_false
    stats.total_request_count.should eq(3)
    stats.response_count.should eq(3)
    stats.transport_error_count.should eq(0)
    stats.ok_requests.should eq(2)
    stats.not_ok_requests.should eq(1)
    stats.total_response_bytes.should eq(300)
    stats.average_bytes_per_response.should be_close(100.0, 0.001)
    stats.status_code_counts.should eq({200 => 1_i64, 201 => 1_i64, 404 => 1_i64})

    view = stats.latency_view
    view.avg.should be_close(20.0, 0.001)
    view.max.should be_close(30.0, 0.001)
    # Sample standard deviation (n-1). v5 divided by n and reported 8.1649.
    view.stdev.should be_close(10.0, 0.001)
  end

  it "supports custom success status ranges" do
    stats = StatsSpecHelper.stats(success_status_ranges: [200..204, 301..304])

    stats.record StatsSpecHelper.sample(10.0, 302)
    stats.record StatsSpecHelper.sample(20.0, 404)

    stats.ok_requests.should eq(1)
    stats.not_ok_requests.should eq(1)
  end

  it "calculates percentiles from the histogram within 1% relative precision" do
    stats = StatsSpecHelper.stats(100)

    (1..100).each { |latency_ms| stats.record StatsSpecHelper.sample(latency_ms.to_f) }

    view = stats.latency_view
    view.p(50.0).should be_close(50.0, 0.5)
    view.p(90.0).should be_close(90.0, 0.9)
    view.p(95.0).should be_close(95.0, 0.95)
    view.p(99.0).should be_close(99.0, 0.99)
    view.p(99.9).should eq(100.0)
  end

  it "keeps sub-millisecond percentiles above zero" do
    stats = StatsSpecHelper.stats

    [0.12, 0.24, 0.36, 0.48].each { |latency_ms| stats.record StatsSpecHelper.sample(latency_ms) }

    view = stats.latency_view
    view.p(50.0).should be_close(0.3, 0.1)
    view.p(99.0).should be >= 0.4
  end

  it "builds rolled-up histogram bins for reporting" do
    stats = StatsSpecHelper.stats(100)

    (1..100).each { |latency_ms| stats.record StatsSpecHelper.sample(latency_ms.to_f) }

    bins = stats.latency_histogram_bins(5)

    bins.size.should eq(5)
    bins.sum(&.count).should eq(100)
    bins.first.start_ms.should be_close(1.0, 0.01)
    bins.last.end_ms.should be_close(100.0, 0.01)
    bins.each(&.count.should(eq(20)))
  end

  it "tracks transport errors without losing run progress" do
    stats = StatsSpecHelper.stats(5)

    stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED, "connect: Connection refused"
    stats.record StatsSpecHelper.sample(15.0)

    stats.total_request_count.should eq(2)
    stats.response_count.should eq(1)
    stats.transport_error_count.should eq(1)

    errors = stats.error_breakdown
    errors.size.should eq(1)
    errors.first.category.should eq("connect_refused")
    errors.first.count.should eq(1)
    errors.first.sample_message.should eq("connect: Connection refused")
    stats.exit_code.should eq(Cryload::ExitCode::Ok)
  end

  it "excludes transport errors from latency metrics" do
    stats = StatsSpecHelper.stats(5)

    stats.record StatsSpecHelper.sample(10.0)
    stats.record StatsSpecHelper.sample(20.0)
    stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED

    view = stats.latency_view
    view.avg.should be_close(15.0, 0.001)
    view.min.should be_close(10.0, 0.001)
    view.max.should be_close(20.0, 0.001)
    view.p(99.0).should be_close(20.0, 0.001)
  end

  it "merges worker-local batches into global stats" do
    stats = StatsSpecHelper.stats
    batch = stats.new_batch

    batch.record StatsSpecHelper.sample(10.0, 200)
    batch.record StatsSpecHelper.sample(30.0, 503, 120_i64)
    batch.record_error 0, Cryload::ErrorCategory::CONNECT_REFUSED, "refused"

    stats.merge_batch batch

    stats.total_request_count.should eq(3)
    stats.response_count.should eq(2)
    stats.total_response_bytes.should eq(120)
    stats.transport_error_count.should eq(1)
    stats.ok_requests.should eq(1)
    stats.not_ok_requests.should eq(1)
    stats.latency_view.avg.should be_close(20.0, 0.001)
    stats.latency_view.p(50.0).should eq(10.0)
    stats.status_code_counts.should eq({200 => 1_i64, 503 => 1_i64})
  end

  describe "phase breakdown" do
    it "records connection phases separately from response phases" do
      stats = StatsSpecHelper.stats

      # Only the request that opened the connection carries phase timings.
      stats.record StatsSpecHelper.sample(10.0, ttfb_ms: 8.0, dns_ms: 1.0, connect_ms: 2.0, tls_ms: 3.0)
      stats.record StatsSpecHelper.sample(12.0, ttfb_ms: 9.0)
      stats.record StatsSpecHelper.sample(14.0, ttfb_ms: 10.0)

      phases = stats.phase_views
      phases["dns"].count.should eq(1)
      phases["connect"].count.should eq(1)
      phases["tls"].count.should eq(1)
      phases["dns"].avg.should be_close(1.0, 0.001)
      phases["connect"].avg.should be_close(2.0, 0.001)
      phases["tls"].avg.should be_close(3.0, 0.001)

      phases["ttfb"].count.should eq(3)
      phases["total"].count.should eq(3)
      phases["ttfb"].avg.should be_close(9.0, 0.001)
      phases["total"].avg.should be_close(12.0, 0.001)
    end
  end

  describe "corrected latency" do
    it "mirrors service latency when there is no request schedule" do
      stats = StatsSpecHelper.stats

      stats.record StatsSpecHelper.sample(10.0)
      stats.record StatsSpecHelper.sample(20.0)

      stats.corrected_latency_view.p(99.0).should eq(stats.latency_view.p(99.0))
      stats.send_delay_view.max.should eq(0.0)
    end

    # The regression that matters. A one second stall inside a rate-limited run
    # delays a whole second's worth of requests, not one: the service time of
    # each stays fast because it is measured from the send, so only the corrected
    # view shows the outage.
    it "surfaces send delay that service latency hides" do
      stats = StatsSpecHelper.stats(100)

      80.times { stats.record StatsSpecHelper.sample(1.0) }
      20.times do |index|
        delay = 1000.0 - (index * 50.0)
        stats.record StatsSpecHelper.sample(1.0, corrected_ms: 1.0 + delay, send_delay_ms: delay)
      end

      stats.latency_view.p(99.0).should be_close(1.0, 0.05)
      stats.corrected_latency_view.p(90.0).should be > 400.0
      stats.corrected_latency_view.p(99.0).should be > 900.0
      stats.send_delay_view.max.should be_close(1000.0, 5.0)
    end

    it "gates on corrected latency by default and on service latency when disabled" do
      corrected = StatsSpecHelper.stats(
        100,
        thresholds: Cryload::CiThresholds.new(thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::P99, 200.0)]),
        config: Cryload::RunConfig.new(latency_correction: true, rate_limit: 500.0),
      )
      uncorrected = StatsSpecHelper.stats(
        100,
        thresholds: Cryload::CiThresholds.new(thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::P99, 200.0)]),
        config: Cryload::RunConfig.new(latency_correction: false, rate_limit: 500.0),
      )

      [corrected, uncorrected].each do |stats|
        80.times { stats.record StatsSpecHelper.sample(1.0) }
        20.times do |index|
          delay = 1000.0 - (index * 50.0)
          stats.record StatsSpecHelper.sample(1.0, corrected_ms: 1.0 + delay, send_delay_ms: delay)
        end
      end

      corrected.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
      corrected.threshold_results.first.metric.should eq("corrected_p99")

      uncorrected.exit_code.should eq(Cryload::ExitCode::Ok)
      uncorrected.threshold_results.first.metric.should eq("p99")
    end
  end

  describe "rate attainment" do
    it "reports nothing but the attained rate when unlimited" do
      stats = StatsSpecHelper.stats(duration_mode: true, benchmark_start: Time.instant - 2.seconds)
      stats.record StatsSpecHelper.sample(1.0)

      report = stats.rate_report
      report.limited?.should be_false
      report.requested.should be_nil
      report.scheduled_requests.should be_nil
      report.skipped_requests.should be_nil
      report.attained.should be_close(0.5, 0.01)
    end

    it "counts the requests the schedule asked for but never got" do
      stats = StatsSpecHelper.stats(
        duration_mode: true,
        benchmark_start: Time.instant - 5.seconds,
        config: Cryload::RunConfig.new(rate_limit: 500.0, duration: 5.seconds),
      )
      2000.times { stats.record StatsSpecHelper.sample(1.0, send_delay_ms: 250.0) }
      stats.mark_benchmark_end

      report = stats.rate_report
      report.scheduled_requests.should eq(2500)
      report.skipped_requests.should eq(500)
      report.attainment_percent.should_not(be_nil).should be_close(80.0, 1.0)
      report.schedule_drift_ms.should_not(be_nil).should be_close(250.0, 0.5)
      report.missed?(Cryload::CiThresholds::RATE_ATTAINMENT_TOLERANCE).should be_true
    end
  end

  describe "breakdowns" do
    it "reports latency per status code" do
      stats = StatsSpecHelper.stats

      10.times { stats.record StatsSpecHelper.sample(5.0, 200) }
      5.times { stats.record StatsSpecHelper.sample(50.0, 503) }

      breakdown = stats.status_breakdown
      breakdown.size.should eq(2)
      breakdown.sum(&.count).should eq(15)

      ok = breakdown.find!(&.code.==(200))
      failed = breakdown.find!(&.code.==(503))
      ok.count.should eq(10)
      ok.p99_ms.should be_close(5.0, 0.1)
      failed.count.should eq(5)
      failed.p99_ms.should be_close(50.0, 0.5)
    end

    it "omits the per-URL breakdown for a single target with no scoped gate" do
      stats = StatsSpecHelper.stats(urls: [URI.parse("http://example.test/one")])
      stats.record StatsSpecHelper.sample(1.0)

      stats.track_urls?.should be_false
      stats.url_breakdown.should be_nil
    end

    it "keeps per-URL stats apart for a multi-URL run" do
      urls = [URI.parse("http://example.test/fast"), URI.parse("http://example.test/slow")]
      stats = StatsSpecHelper.stats(urls: urls, benchmark_start: Time.instant - 1.second)

      10.times { stats.record StatsSpecHelper.sample(2.0, 200, url_index: 0) }
      10.times { stats.record StatsSpecHelper.sample(200.0, 200, url_index: 1) }
      stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED, "refused", 1

      breakdown = stats.url_breakdown.should_not be_nil
      breakdown.size.should eq(2)
      breakdown.sum(&.requests).should eq(stats.total_request_count)

      fast = breakdown.find!(&.url.ends_with?("/fast"))
      slow = breakdown.find!(&.url.ends_with?("/slow"))

      fast.requests.should eq(10)
      fast.transport_errors.should eq(0)
      fast.p99_ms.should be_close(2.0, 0.1)

      slow.requests.should eq(11)
      slow.transport_errors.should eq(1)
      slow.p99_ms.should be_close(200.0, 2.0)
      slow.failure_rate_percent.should be_close(9.09, 0.1)
    end

    it "tracks per-URL stats for a single target when a scoped gate needs them" do
      stats = StatsSpecHelper.stats(
        urls: [URI.parse("http://example.test/api/users")],
        thresholds: Cryload::CiThresholds.new(
          thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::P99, 50.0, "/api/users")]
        ),
      )
      stats.record StatsSpecHelper.sample(1.0)

      stats.track_urls?.should be_true
      stats.url_breakdown.should_not(be_nil).size.should eq(1)
    end
  end

  describe "verdict" do
    it "passes with no thresholds configured" do
      stats = StatsSpecHelper.stats
      stats.record StatsSpecHelper.sample(10.0, 404)

      stats.exit_code.should eq(Cryload::ExitCode::Ok)
      stats.threshold_results.should be_empty
    end

    it "reports an unreachable target separately from a threshold breach" do
      stats = StatsSpecHelper.stats(2)
      2.times { stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED }

      stats.target_unreachable?.should be_true
      stats.exit_code.should eq(Cryload::ExitCode::TargetUnreachable)
    end

    it "does not call a partially failing run unreachable" do
      stats = StatsSpecHelper.stats(2)
      stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED
      stats.record StatsSpecHelper.sample(10.0)

      stats.target_unreachable?.should be_false
      stats.exit_code.should eq(Cryload::ExitCode::Ok)
    end

    it "honours the fail-on-error flags" do
      on_http = StatsSpecHelper.stats(thresholds: Cryload::CiThresholds.new(fail_on_error: true))
      on_http.record StatsSpecHelper.sample(10.0, 404)
      on_http.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)

      on_transport = StatsSpecHelper.stats(thresholds: Cryload::CiThresholds.new(fail_on_transport_error: true))
      on_transport.record_error Cryload::ErrorCategory::READ_TIMEOUT
      on_transport.record StatsSpecHelper.sample(15.0)
      on_transport.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
    end

    it "evaluates the failure-rate gate against the requested limit" do
      breached = StatsSpecHelper.stats(
        thresholds: Cryload::CiThresholds.new(thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::FailRate, 10.0)])
      )
      passing = StatsSpecHelper.stats(
        thresholds: Cryload::CiThresholds.new(thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::FailRate, 60.0)])
      )

      [breached, passing].each do |stats|
        stats.record StatsSpecHelper.sample(10.0, 200)
        stats.record StatsSpecHelper.sample(20.0, 404)
      end

      breached.failure_rate_percent.should eq(50.0)
      breached.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
      passing.exit_code.should eq(Cryload::ExitCode::Ok)
    end

    it "evaluates every latency metric of the threshold matrix" do
      metrics = {
        Cryload::Threshold::Metric::P50        => "p50",
        Cryload::Threshold::Metric::P75        => "p75",
        Cryload::Threshold::Metric::P90        => "p90",
        Cryload::Threshold::Metric::P95        => "p95",
        Cryload::Threshold::Metric::P99        => "p99",
        Cryload::Threshold::Metric::P999       => "p999",
        Cryload::Threshold::Metric::Avg        => "avg",
        Cryload::Threshold::Metric::MaxLatency => "max",
      }

      metrics.each do |metric, label|
        stats = StatsSpecHelper.stats(
          100,
          thresholds: Cryload::CiThresholds.new(thresholds: [StatsSpecHelper.threshold(metric, 0.5)]),
        )
        (1..100).each { |latency_ms| stats.record StatsSpecHelper.sample(latency_ms.to_f) }

        result = stats.threshold_results.first
        result.metric.should eq("corrected_#{label}")
        result.comparator.should eq("<=")
        result.passed?.should be_false
        stats.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
      end
    end

    it "treats min-rps as a floor rather than a ceiling" do
      stats = StatsSpecHelper.stats(
        duration_mode: true,
        benchmark_start: Time.instant - 2.seconds,
        thresholds: Cryload::CiThresholds.new(thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::Rps, 100.0)]),
      )
      stats.record StatsSpecHelper.sample(1.0)
      stats.mark_benchmark_end

      result = stats.threshold_results.first
      result.name.should eq("min-rps")
      result.comparator.should eq(">=")
      result.passed?.should be_false
      stats.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
    end

    it "scopes a gate to the endpoints its pattern matches" do
      urls = [URI.parse("http://example.test/fast"), URI.parse("http://example.test/slow")]

      slow_gate = StatsSpecHelper.stats(
        urls: urls,
        thresholds: Cryload::CiThresholds.new(
          thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::P99, 50.0, "/slow")]
        ),
      )
      fast_gate = StatsSpecHelper.stats(
        urls: urls,
        thresholds: Cryload::CiThresholds.new(
          thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::P99, 50.0, "/fast")]
        ),
      )

      [slow_gate, fast_gate].each do |stats|
        10.times { stats.record StatsSpecHelper.sample(2.0, url_index: 0) }
        10.times { stats.record StatsSpecHelper.sample(500.0, url_index: 1) }
      end

      slow_gate.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
      slow_gate.threshold_results.first.scope.should eq("/slow")
      fast_gate.exit_code.should eq(Cryload::ExitCode::Ok)
    end

    it "fails a scoped gate on the worst matching endpoint" do
      urls = [URI.parse("http://example.test/api/a"), URI.parse("http://example.test/api/b")]
      stats = StatsSpecHelper.stats(
        urls: urls,
        thresholds: Cryload::CiThresholds.new(
          thresholds: [StatsSpecHelper.threshold(Cryload::Threshold::Metric::P99, 50.0, "/api/")]
        ),
      )

      10.times { stats.record StatsSpecHelper.sample(2.0, url_index: 0) }
      10.times { stats.record StatsSpecHelper.sample(500.0, url_index: 1) }

      stats.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
      stats.threshold_results.first.actual.should be > 400.0
    end

    it "fails on a rate miss only when asked to" do
      config = Cryload::RunConfig.new(rate_limit: 500.0, duration: 5.seconds)

      silent = StatsSpecHelper.stats(duration_mode: true, benchmark_start: Time.instant - 5.seconds, config: config)
      loud = StatsSpecHelper.stats(
        duration_mode: true,
        benchmark_start: Time.instant - 5.seconds,
        config: config,
        thresholds: Cryload::CiThresholds.new(fail_on_rate_miss: true),
      )

      [silent, loud].each do |stats|
        1000.times { stats.record StatsSpecHelper.sample(1.0) }
        stats.mark_benchmark_end
      end

      silent.exit_code.should eq(Cryload::ExitCode::Ok)
      loud.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
    end
  end

  describe "timing window" do
    it "uses actual elapsed time for throughput calculations" do
      stats = StatsSpecHelper.stats(duration_mode: true, benchmark_start: Time.instant - 2.seconds)

      stats.record StatsSpecHelper.sample(100.0)

      stats.wall_clock_seconds.should be_close(2.0, 0.05)
      stats.request_per_second.should be_close(0.5, 0.05)
    end

    it "freezes the window at the benchmark end marker" do
      stats = StatsSpecHelper.stats(duration_mode: true, benchmark_start: Time.instant - 2.seconds)
      stats.mark_benchmark_end
      sleep 50.milliseconds

      stats.wall_clock_seconds.should be_close(2.0, 0.05)
    end

    it "restarts the window after warmup so warmup does not count as load" do
      stats = StatsSpecHelper.stats(benchmark_start: Time.instant - 3.seconds)
      stats.start_benchmark_window
      stats.record StatsSpecHelper.sample(1.0)

      stats.wall_clock_seconds.should be < 0.5
    end
  end
end
