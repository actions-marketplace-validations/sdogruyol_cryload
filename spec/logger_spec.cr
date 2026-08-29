require "./spec_helper"
require "csv"

module LoggerSpecHelper
  extend self

  def sample(
    total_ms : Float64,
    status : Int32 = 200,
    bytes : Int64 = 0_i64,
    url_index : Int32 = 0,
    corrected_ms : Float64? = nil,
    send_delay_ms : Float64 = 0.0,
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
      ttfb_ms: total_ms,
      response_bytes: bytes,
      dns_ms: dns_ms,
      connect_ms: connect_ms,
      tls_ms: tls_ms,
    )
  end

  def report(stats : Cryload::Stats, signal : Cryload::ExitCode? = nil) : Cryload::Logger::Report
    Cryload::Logger::Report.new(stats, signal)
  end
end

describe Cryload::Logger::Report do
  it "builds a versioned JSON document from stats" do
    stats = Cryload::Stats.new(3, url: "http://example.test/run")
    stats.record LoggerSpecHelper.sample(10.0, 200, 12_i64, dns_ms: 1.0, connect_ms: 2.0)
    stats.record LoggerSpecHelper.sample(20.0, 404, 8_i64)
    stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED, "connect: Connection refused"

    parsed = JSON.parse(LoggerSpecHelper.report(stats).to_json)

    parsed["schema_version"].as_i.should eq(1)
    parsed["cryload_version"].as_s.should_not be_empty
    parsed["url"].as_s.should eq("http://example.test/run")
    parsed["summary"]["requests"].as_i.should eq(3)
    parsed["summary"]["responses"].as_i.should eq(2)
    parsed["summary"]["transport_errors"].as_i.should eq(1)
    parsed["summary"]["failure_rate_percent"].as_f.should eq(66.67)
    parsed["latency_ms"]["p50"].as_f.should eq(10.0)
    parsed["status"]["successful_count"].as_i.should eq(1)
    parsed["status"]["failed_count"].as_i.should eq(1)
    parsed["status"]["codes"].as_a.size.should eq(2)
    parsed["latency_histogram"].as_a.size.should be > 0

    error = parsed["status"]["transport_errors"].as_a.first
    error["category"].as_s.should eq("connect_refused")
    error["sample_message"].as_s.should contain("refused")
  end

  it "reports every v6 block, with nulls where a block does not apply" do
    stats = Cryload::Stats.new(2, url: "http://example.test/run")
    stats.record LoggerSpecHelper.sample(10.0, 200, 5_i64, dns_ms: 1.0, connect_ms: 2.0, tls_ms: 3.0)
    stats.record LoggerSpecHelper.sample(20.0, 200, 5_i64)

    parsed = JSON.parse(LoggerSpecHelper.report(stats).to_json)

    parsed["config"]["workers"].as_i.should be > 0
    parsed["config"]["latency_correction"].as_bool.should be_true
    parsed["config"]["request_timeout_seconds"].raw.should be_nil

    # No --rate, so there is no schedule: everything but the attained rate is null
    # and corrected latency mirrors service latency exactly.
    parsed["rate"]["requested_per_second"].raw.should be_nil
    parsed["rate"]["scheduled_requests"].raw.should be_nil
    parsed["rate"]["attained_per_second"].as_f.should be >= 0.0
    parsed["corrected_latency_ms"].as_h.each do |key, value|
      value.as_f.should eq(parsed["latency_ms"][key].as_f)
    end

    parsed["phases_ms"]["dns"]["count"].as_i.should eq(1)
    parsed["phases_ms"]["tls"]["count"].as_i.should eq(1)
    parsed["phases_ms"]["ttfb"]["count"].as_i.should eq(2)
    parsed["phases_ms"]["total"]["count"].as_i.should eq(2)

    parsed["by_status"].as_a.size.should eq(1)
    parsed["by_status"].as_a.first["code"].as_i.should eq(200)
    parsed["by_url"].raw.should be_nil

    parsed["thresholds"]["passed"].as_bool.should be_true
    parsed["thresholds"]["evaluated"].as_a.should be_empty
    parsed["thresholds"]["breached"].as_a.should be_empty
    parsed["verdict"]["exit_code"].as_i.should eq(0)
    parsed["verdict"]["reason"].as_s.should eq("ok")
  end

  it "reports the rate schedule and per-URL breakdown when they apply" do
    urls = [URI.parse("http://example.test/a"), URI.parse("http://example.test/b")]
    stats = Cryload::Stats.new(
      -1,
      duration_mode: true,
      benchmark_start: Time.instant - 5.seconds,
      url: "http://example.test/a (+1 more)",
      config: Cryload::RunConfig.new(rate_limit: 100.0, duration: 5.seconds),
      urls: urls,
    )
    200.times { |index| stats.record LoggerSpecHelper.sample(5.0, 200, 1_i64, url_index: index % 2, send_delay_ms: 40.0) }
    stats.mark_benchmark_end

    parsed = JSON.parse(LoggerSpecHelper.report(stats).to_json)

    parsed["rate"]["requested_per_second"].as_f.should eq(100.0)
    parsed["rate"]["scheduled_requests"].as_i.should eq(500)
    parsed["rate"]["skipped_requests"].as_i.should eq(300)
    parsed["rate"]["attainment_percent"].as_f.should be_close(40.0, 1.0)
    parsed["rate"]["schedule_drift_ms"].as_f.should be_close(40.0, 0.5)
    parsed["send_delay_ms"]["p99"].as_f.should be_close(40.0, 0.5)

    by_url = parsed["by_url"].as_a
    by_url.size.should eq(2)
    by_url.sum(&.["requests"].as_i).should eq(200)
    by_url.first["p99_ms"].as_f.should be_close(5.0, 0.1)
  end

  it "records the verdict of every evaluated threshold" do
    stats = Cryload::Stats.new(
      100,
      url: "http://example.test/run",
      ci_thresholds: Cryload::CiThresholds.new(
        thresholds: [
          Cryload::Threshold.new(Cryload::Threshold::Metric::P99, 500.0),
          Cryload::Threshold.new(Cryload::Threshold::Metric::P50, 1.0),
        ]
      ),
    )
    (1..100).each { |latency_ms| stats.record LoggerSpecHelper.sample(latency_ms.to_f) }

    report = LoggerSpecHelper.report(stats)
    parsed = JSON.parse(report.to_json)

    parsed["thresholds"]["passed"].as_bool.should be_false
    breached = parsed["thresholds"]["breached"].as_a
    breached.size.should eq(1)
    breached.first["name"].as_s.should eq("max-p50")
    breached.first["metric"].as_s.should eq("corrected_p50")
    breached.first["passed"].as_bool.should be_false

    p99 = parsed["thresholds"]["evaluated"].as_a.find! { |entry| entry["name"].as_s == "max-p99" }
    p99["scope"].as_s.should eq("global")
    p99["metric"].as_s.should eq("corrected_p99")
    p99["comparator"].as_s.should eq("<=")
    p99["passed"].as_bool.should be_true

    parsed["verdict"]["exit_code"].as_i.should eq(1)
    parsed["verdict"]["reason"].as_s.should eq("threshold_breached")
    report.exit_code.should eq(Cryload::ExitCode::ThresholdBreach)
  end

  it "reports an unreachable target as its own verdict" do
    stats = Cryload::Stats.new(2, url: "http://example.test/run")
    2.times { stats.record_error Cryload::ErrorCategory::CONNECT_REFUSED, "refused" }

    parsed = JSON.parse(LoggerSpecHelper.report(stats).to_json)

    parsed["verdict"]["exit_code"].as_i.should eq(3)
    parsed["verdict"]["reason"].as_s.should eq("target_unreachable")
  end

  it "keeps a signal verdict unless a threshold was breached" do
    clean = Cryload::Stats.new(1, url: "http://example.test/run")
    clean.record LoggerSpecHelper.sample(5.0)

    breached = Cryload::Stats.new(
      1,
      url: "http://example.test/run",
      ci_thresholds: Cryload::CiThresholds.new(
        thresholds: [Cryload::Threshold.new(Cryload::Threshold::Metric::P99, 0.001)]
      ),
    )
    breached.record LoggerSpecHelper.sample(5.0)

    LoggerSpecHelper.report(clean, Cryload::ExitCode::Interrupted).exit_code
      .should eq(Cryload::ExitCode::Interrupted)
    JSON.parse(LoggerSpecHelper.report(clean, Cryload::ExitCode::Interrupted).to_json)["verdict"]["reason"]
      .as_s.should eq("interrupted")
    LoggerSpecHelper.report(breached, Cryload::ExitCode::Interrupted).exit_code
      .should eq(Cryload::ExitCode::ThresholdBreach)
  end

  it "builds CSV documents whose v5 columns keep their names and order" do
    stats = Cryload::Stats.new(2, url: "http://example.test/csv", duration_mode: true)
    stats.record LoggerSpecHelper.sample(15.0, 201, 100_i64)
    stats.record LoggerSpecHelper.sample(25.0, 201, 50_i64)

    rows = CSV.parse(LoggerSpecHelper.report(stats).to_csv)
    rows.size.should eq(2)

    headers = rows[0]
    values = rows[1]

    # The v5 prefix is the compatibility guarantee: v6 columns are appended.
    headers[0, 27].should eq([
      "url", "duration_mode", "requests", "responses", "transport_errors",
      "elapsed_seconds", "requests_per_second", "transfer_total_bytes",
      "transfer_size_per_request_bytes", "transfer_bytes_per_second",
      "latency_avg_ms", "latency_min_ms", "latency_stdev_ms", "latency_max_ms",
      "latency_p50_ms", "latency_p90_ms", "latency_p95_ms", "latency_p99_ms",
      "latency_p999_ms", "status_successful_count", "status_successful_percent",
      "status_failed_count", "status_failed_percent", "transport_error_percent",
      "status_successes", "status_code_distribution", "transport_error_distribution",
    ])

    values[0].should eq("http://example.test/csv")
    values[1].should eq("true")
    values[2].should eq("2")
    values[3].should eq("2")
    values[4].should eq("0")
    values[headers.index!("latency_p95_ms")].to_f.should be_close(25.0, 0.25)
    values[headers.index!("status_successful_count")].should eq("2")

    values[headers.index!("schema_version")].should eq("1")
    values[headers.index!("cryload_version")].should_not be_empty
    values[headers.index!("latency_correction")].should eq("true")
    values[headers.index!("latency_corrected_p99_ms")].to_f.should be_close(25.0, 0.25)
    values[headers.index!("rate_requested_per_second")].should eq("")
    values[headers.index!("thresholds_passed")].should eq("true")
    values[headers.index!("thresholds_breached")].should eq("")
    values[headers.index!("exit_code")].should eq("0")
  end

  it "fills the appended CSV columns for a rate-limited gated run" do
    stats = Cryload::Stats.new(
      -1,
      duration_mode: true,
      benchmark_start: Time.instant - 2.seconds,
      url: "http://example.test/csv",
      config: Cryload::RunConfig.new(rate_limit: 50.0, duration: 2.seconds, workers: 4),
      ci_thresholds: Cryload::CiThresholds.new(
        thresholds: [Cryload::Threshold.new(Cryload::Threshold::Metric::P99, 0.001)]
      ),
    )
    20.times { stats.record LoggerSpecHelper.sample(10.0, 200, 1_i64, send_delay_ms: 5.0) }
    stats.mark_benchmark_end

    rows = CSV.parse(LoggerSpecHelper.report(stats).to_csv)
    headers, values = rows[0], rows[1]

    values[headers.index!("workers")].should eq("4")
    values[headers.index!("rate_requested_per_second")].to_f.should eq(50.0)
    values[headers.index!("rate_attainment_percent")].to_f.should be_close(20.0, 1.0)
    values[headers.index!("rate_skipped_requests")].should eq("80")
    values[headers.index!("rate_schedule_drift_ms")].to_f.should be_close(5.0, 0.1)
    values[headers.index!("send_delay_p99_ms")].to_f.should be_close(5.0, 0.1)
    values[headers.index!("thresholds_passed")].should eq("false")
    values[headers.index!("thresholds_breached")].should eq("corrected_p99<=0.001")
    values[headers.index!("exit_code")].should eq("1")
  end
end
