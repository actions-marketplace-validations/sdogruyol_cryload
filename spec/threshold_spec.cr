require "./spec_helper"

module ThresholdSpec
  extend self

  # The documented `--url-threshold` / flag spelling, JSON label and percentile
  # of every metric. Driven by `Metric.each` in the specs below so a new member
  # cannot slip in without a decision recorded here.
  FLAGS = {
    Cryload::Threshold::Metric::P50        => "max-p50",
    Cryload::Threshold::Metric::P75        => "max-p75",
    Cryload::Threshold::Metric::P90        => "max-p90",
    Cryload::Threshold::Metric::P95        => "max-p95",
    Cryload::Threshold::Metric::P99        => "max-p99",
    Cryload::Threshold::Metric::P999       => "max-p999",
    Cryload::Threshold::Metric::Avg        => "max-avg",
    Cryload::Threshold::Metric::MaxLatency => "max-latency",
    Cryload::Threshold::Metric::FailRate   => "max-fail-rate",
    Cryload::Threshold::Metric::Rps        => "min-rps",
  }

  LABELS = {
    Cryload::Threshold::Metric::P50        => "p50",
    Cryload::Threshold::Metric::P75        => "p75",
    Cryload::Threshold::Metric::P90        => "p90",
    Cryload::Threshold::Metric::P95        => "p95",
    Cryload::Threshold::Metric::P99        => "p99",
    Cryload::Threshold::Metric::P999       => "p999",
    Cryload::Threshold::Metric::Avg        => "avg",
    Cryload::Threshold::Metric::MaxLatency => "max",
    Cryload::Threshold::Metric::FailRate   => "fail_rate_percent",
    Cryload::Threshold::Metric::Rps        => "requests_per_second",
  }

  PERCENTILES = Hash(Cryload::Threshold::Metric, Float64?){
    Cryload::Threshold::Metric::P50        => 50.0,
    Cryload::Threshold::Metric::P75        => 75.0,
    Cryload::Threshold::Metric::P90        => 90.0,
    Cryload::Threshold::Metric::P95        => 95.0,
    Cryload::Threshold::Metric::P99        => 99.0,
    Cryload::Threshold::Metric::P999       => 99.9,
    Cryload::Threshold::Metric::Avg        => nil,
    Cryload::Threshold::Metric::MaxLatency => nil,
    Cryload::Threshold::Metric::FailRate   => nil,
    Cryload::Threshold::Metric::Rps        => nil,
  }

  def parse(raw : String) : Array(Cryload::Threshold)
    Cryload::Cli::Validator.parse_url_thresholds([raw])
  end

  # `CiThresholds#any?` is its own predicate, not `Enumerable#any?`; the lint
  # rule cannot tell them apart, so the call is funnelled through here once.
  def configured?(thresholds : Cryload::CiThresholds) : Bool
    thresholds.any? # ameba:disable Performance/AnyInsteadOfPresent
  end
end

describe Cryload::Threshold::Metric do
  it "spells every member's flag, label and percentile as documented" do
    seen = 0
    Cryload::Threshold::Metric.each do |metric|
      ThresholdSpec::FLAGS.has_key?(metric).should be_true
      ThresholdSpec::LABELS.has_key?(metric).should be_true
      ThresholdSpec::PERCENTILES.has_key?(metric).should be_true

      metric.flag.should eq(ThresholdSpec::FLAGS[metric])
      metric.label.should eq(ThresholdSpec::LABELS[metric])
      metric.percentile.should eq(ThresholdSpec::PERCENTILES[metric])
      seen += 1
    end
    seen.should eq(ThresholdSpec::FLAGS.size)
  end

  it "returns a percentile only for the percentile metrics" do
    Cryload::Threshold::Metric::P50.percentile.should eq(50.0)
    Cryload::Threshold::Metric::P999.percentile.should eq(99.9)
    Cryload::Threshold::Metric::Avg.percentile.should be_nil
    Cryload::Threshold::Metric::MaxLatency.percentile.should be_nil
    Cryload::Threshold::Metric::FailRate.percentile.should be_nil
    Cryload::Threshold::Metric::Rps.percentile.should be_nil
  end

  it "treats only fail rate and throughput as non-latency metrics" do
    non_latency = [] of Cryload::Threshold::Metric
    Cryload::Threshold::Metric.each { |metric| non_latency << metric unless metric.latency? }
    non_latency.should eq([Cryload::Threshold::Metric::FailRate, Cryload::Threshold::Metric::Rps])
  end
end

describe Cryload::Threshold::Comparator do
  it "renders the symbol used in the report" do
    Cryload::Threshold::Comparator::AtMost.symbol.should eq("<=")
    Cryload::Threshold::Comparator::AtLeast.symbol.should eq(">=")
  end

  it "implements <= for AtMost, boundary inclusive" do
    at_most = Cryload::Threshold::Comparator::AtMost
    at_most.satisfied?(99.0, 100.0).should be_true
    at_most.satisfied?(100.0, 100.0).should be_true
    at_most.satisfied?(100.1, 100.0).should be_false
  end

  it "implements >= for AtLeast, boundary inclusive" do
    at_least = Cryload::Threshold::Comparator::AtLeast
    at_least.satisfied?(101.0, 100.0).should be_true
    at_least.satisfied?(100.0, 100.0).should be_true
    at_least.satisfied?(99.9, 100.0).should be_false
  end
end

describe Cryload::Threshold do
  it "compares throughput upward and everything else downward" do
    Cryload::Threshold::Metric.each do |metric|
      expected = metric.rps? ? Cryload::Threshold::Comparator::AtLeast : Cryload::Threshold::Comparator::AtMost
      Cryload::Threshold.new(metric, 1.0).comparator.should eq(expected)
    end
  end

  it "names itself after its flag" do
    Cryload::Threshold.new(Cryload::Threshold::Metric::P99, 120.0).name.should eq("max-p99")
    Cryload::Threshold.new(Cryload::Threshold::Metric::Rps, 500.0).name.should eq("min-rps")
  end

  it "defaults to run-wide scope" do
    Cryload::Threshold.new(Cryload::Threshold::Metric::Avg, 10.0).scope.should be_nil
    Cryload::Threshold.new(Cryload::Threshold::Metric::Avg, 10.0, "/api").scope.should eq("/api")
  end
end

describe Cryload::CiThresholds do
  it "reports nothing configured by default" do
    thresholds = Cryload::CiThresholds.new
    ThresholdSpec.configured?(thresholds).should be_false
    thresholds.scoped?.should be_false
    thresholds.global.should be_empty
    thresholds.scoped.should be_empty
  end

  it "counts a bare failure gate as configured" do
    ThresholdSpec.configured?(Cryload::CiThresholds.new(fail_on_error: true)).should be_true
    ThresholdSpec.configured?(Cryload::CiThresholds.new(fail_on_transport_error: true)).should be_true
    ThresholdSpec.configured?(Cryload::CiThresholds.new(fail_on_rate_miss: true)).should be_true
  end

  it "partitions global and scoped gates" do
    global_p99 = Cryload::Threshold.new(Cryload::Threshold::Metric::P99, 200.0)
    global_rps = Cryload::Threshold.new(Cryload::Threshold::Metric::Rps, 500.0)
    scoped_p95 = Cryload::Threshold.new(Cryload::Threshold::Metric::P95, 80.0, "/api/users")
    scoped_avg = Cryload::Threshold.new(Cryload::Threshold::Metric::Avg, 40.0, "/health")

    thresholds = Cryload::CiThresholds.new(
      thresholds: [global_p99, scoped_p95, global_rps, scoped_avg],
    )

    ThresholdSpec.configured?(thresholds).should be_true
    thresholds.scoped?.should be_true
    thresholds.global.should eq([global_p99, global_rps])
    thresholds.scoped.should eq([scoped_p95, scoped_avg])
  end

  it "reports no scoped gates when every gate is run-wide" do
    thresholds = Cryload::CiThresholds.new(
      thresholds: [Cryload::Threshold.new(Cryload::Threshold::Metric::P99, 200.0)],
    )
    thresholds.scoped?.should be_false
    thresholds.scoped.should be_empty
    thresholds.global.size.should eq(1)
  end
end

describe Cryload::ExitCode do
  it "uses the documented numeric values" do
    Cryload::ExitCode::Ok.value.should eq(0)
    Cryload::ExitCode::ThresholdBreach.value.should eq(1)
    Cryload::ExitCode::ConfigError.value.should eq(2)
    Cryload::ExitCode::TargetUnreachable.value.should eq(3)
    Cryload::ExitCode::Interrupted.value.should eq(130)
    Cryload::ExitCode::Terminated.value.should eq(143)
  end

  it "reports a machine-readable reason for every member" do
    expected = {
      Cryload::ExitCode::Ok                => "ok",
      Cryload::ExitCode::ThresholdBreach   => "threshold_breached",
      Cryload::ExitCode::ConfigError       => "config_error",
      Cryload::ExitCode::TargetUnreachable => "target_unreachable",
      Cryload::ExitCode::Interrupted       => "interrupted",
      Cryload::ExitCode::Terminated        => "terminated",
    }

    seen = 0
    Cryload::ExitCode.each do |code|
      expected.has_key?(code).should be_true
      code.reason.should eq(expected[code])
      seen += 1
    end
    seen.should eq(expected.size)
  end
end

describe "Cryload::Cli::Validator.parse_url_thresholds" do
  it "parses a pattern, metric and limit" do
    thresholds = ThresholdSpec.parse("/api/users max-p99 120")
    thresholds.size.should eq(1)

    threshold = thresholds.first
    threshold.scope.should eq("/api/users")
    threshold.metric.should eq(Cryload::Threshold::Metric::P99)
    threshold.limit.should eq(120.0)
    threshold.comparator.should eq(Cryload::Threshold::Comparator::AtMost)
  end

  it "tolerates any amount of surrounding and internal whitespace" do
    threshold = ThresholdSpec.parse("   /api/users \t  max-p99    120  ").first
    threshold.scope.should eq("/api/users")
    threshold.metric.should eq(Cryload::Threshold::Metric::P99)
    threshold.limit.should eq(120.0)
  end

  it "is case insensitive on the metric" do
    ThresholdSpec.parse("/api MAX-P95 80").first.metric.should eq(Cryload::Threshold::Metric::P95)
    ThresholdSpec.parse("/api Min-Rps 500").first.metric.should eq(Cryload::Threshold::Metric::Rps)
  end

  it "accepts every documented metric name" do
    {
      "max-p50"       => Cryload::Threshold::Metric::P50,
      "max-p75"       => Cryload::Threshold::Metric::P75,
      "max-p90"       => Cryload::Threshold::Metric::P90,
      "max-p95"       => Cryload::Threshold::Metric::P95,
      "max-p99"       => Cryload::Threshold::Metric::P99,
      "max-p999"      => Cryload::Threshold::Metric::P999,
      "max-avg"       => Cryload::Threshold::Metric::Avg,
      "max-latency"   => Cryload::Threshold::Metric::MaxLatency,
      "max-fail-rate" => Cryload::Threshold::Metric::FailRate,
      "min-rps"       => Cryload::Threshold::Metric::Rps,
    }.each do |name, metric|
      ThresholdSpec.parse("/api #{name} 5").first.metric.should eq(metric)
    end
  end

  it "parses several gates in one call" do
    thresholds = Cryload::Cli::Validator.parse_url_thresholds(
      ["/api max-p99 120", "/health max-avg 10"],
    )
    thresholds.map(&.scope).should eq(["/api", "/health"])
    thresholds.map(&.limit).should eq([120.0, 10.0])
  end

  it "rejects the wrong number of fields" do
    expect_raises(ArgumentError, /--url-threshold/) { ThresholdSpec.parse("/api max-p99") }
    expect_raises(ArgumentError, /--url-threshold/) { ThresholdSpec.parse("/api max-p99 120 extra") }
  end

  it "rejects an unknown metric" do
    expect_raises(ArgumentError, /--url-threshold metric 'max-p42'/) do
      ThresholdSpec.parse("/api max-p42 120")
    end
  end

  it "rejects a non-numeric limit" do
    expect_raises(ArgumentError, /--url-threshold value 'fast'/) do
      ThresholdSpec.parse("/api max-p99 fast")
    end
  end

  it "rejects a zero or negative limit" do
    expect_raises(ArgumentError, /--url-threshold value '0'/) do
      ThresholdSpec.parse("/api max-p99 0")
    end
    expect_raises(ArgumentError, /--url-threshold value '-5'/) do
      ThresholdSpec.parse("/api max-p99 -5")
    end
  end

  it "rejects a missing URL pattern" do
    expect_raises(ArgumentError, /--url-threshold/) { ThresholdSpec.parse(" max-p99 120") }
    expect_raises(ArgumentError, /--url-threshold/) { ThresholdSpec.parse("") }
  end
end
