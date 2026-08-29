require "./spec_helper"

module HistogramSpec
  extend self

  # Deterministic pseudo-random latencies spanning three orders of magnitude, so
  # the batching property is exercised across many buckets rather than one.
  def sample_values(count : Int32) : Array(Float64)
    random = Random.new(20_260_829)
    Array(Float64).new(count) { random.rand * 999.0 + 1.0 }
  end

  def dense(values : Enumerable(Float64), batch_size : Int32) : Cryload::Histogram::Dense
    aggregate = Cryload::Histogram::Dense.new
    values.each_slice(batch_size) do |batch|
      sparse = Cryload::Histogram::Sparse.new
      batch.each { |value| sparse.record(value) }
      aggregate.merge(sparse)
    end
    aggregate
  end

  def dense(values : Enumerable(Float64)) : Cryload::Histogram::Dense
    aggregate = Cryload::Histogram::Dense.new
    sparse = Cryload::Histogram::Sparse.new
    values.each { |value| sparse.record(value) }
    aggregate.merge(sparse)
    aggregate
  end
end

describe Cryload::Histogram do
  describe ".bucket_index" do
    it "is monotonically non-decreasing across the supported range" do
      previous = -1
      value = Cryload::Histogram::MIN_MS
      while value <= 100_000.0
        index = Cryload::Histogram.bucket_index(value)
        index.should be >= previous
        previous = index
        value *= 1.003
      end
    end

    it "clamps values at or below the floor to the first bucket" do
      Cryload::Histogram.bucket_index(0.0).should eq(0)
      Cryload::Histogram.bucket_index(Cryload::Histogram::MIN_MS).should eq(0)
    end

    it "clamps values above the ceiling to the last bucket" do
      Cryload::Histogram.bucket_index(Cryload::Histogram::MAX_MS * 10).should eq(Cryload::Histogram::BUCKET_COUNT - 1)
    end
  end

  describe ".bucket_value" do
    it "round-trips a value through its bucket within 1 percent" do
      [0.01, 0.5, 1.0, 7.5, 123.4, 999.0, 25_000.0].each do |value|
        estimate = Cryload::Histogram.bucket_value(Cryload::Histogram.bucket_index(value))
        ((estimate - value).abs / value).should be < 0.01
      end
    end

    it "increases with the bucket index" do
      previous = 0.0
      0.step(to: Cryload::Histogram::BUCKET_COUNT - 1, by: 25) do |index|
        current = Cryload::Histogram.bucket_value(index)
        current.should be > previous
        previous = current
      end
    end
  end

  describe Cryload::Histogram::Sparse do
    it "starts empty" do
      sparse = Cryload::Histogram::Sparse.new
      sparse.empty?.should be_true
      sparse.count.should eq(0)
      sparse.sum.should eq(0.0)
      sparse.buckets.should be_empty
    end

    it "tracks count, sum, min and max as values arrive" do
      sparse = Cryload::Histogram::Sparse.new
      [12.0, 3.0, 40.0, 25.0].each { |value| sparse.record(value) }

      sparse.empty?.should be_false
      sparse.count.should eq(4)
      sparse.sum.should be_close(80.0, 1e-9)
      sparse.min.should eq(3.0)
      sparse.max.should eq(40.0)
      sparse.buckets.values.sum.should eq(4)
    end
  end

  describe Cryload::Histogram::Dense do
    it "reports zero for every statistic while empty" do
      dense = Cryload::Histogram::Dense.new
      dense.empty?.should be_true
      dense.avg.should eq(0.0)
      dense.minimum.should eq(0.0)
      dense.maximum.should eq(0.0)
      dense.stdev.should eq(0.0)
      dense.percentile(50.0).should eq(0.0)
      dense.percentile(99.9).should eq(0.0)
      dense.linear_bins(5).should be_empty
    end

    it "ignores an empty merge" do
      dense = Cryload::Histogram::Dense.new
      dense.merge(Cryload::Histogram::Sparse.new)
      dense.empty?.should be_true
      dense.count.should eq(0)
    end

    it "merges batched sparse histograms exactly like a single batch" do
      values = HistogramSpec.sample_values(600)
      batched = HistogramSpec.dense(values, 37)
      whole = HistogramSpec.dense(values)

      batched.count.should eq(whole.count)
      batched.count.should eq(600)
      batched.minimum.should eq(whole.minimum)
      batched.maximum.should eq(whole.maximum)
      batched.avg.should be_close(whole.avg, 1e-9)
      batched.stdev.should be_close(whole.stdev, 1e-9)

      [50.0, 75.0, 90.0, 95.0, 99.0, 99.9].each do |percentile|
        batched.percentile(percentile).should eq(whole.percentile(percentile))
      end

      batched.linear_bins(11).map(&.count).should eq(whole.linear_bins(11).map(&.count))
    end

    it "computes percentiles within 1 percent of the true rank" do
      dense = HistogramSpec.dense((1..1000).map(&.to_f), 100)

      {50.0 => 500.0, 90.0 => 900.0, 95.0 => 950.0, 99.0 => 990.0, 99.9 => 999.0}.each do |percentile, expected|
        actual = dense.percentile(percentile)
        ((actual - expected).abs / expected).should be < 0.01
      end
    end

    it "never reports a percentile outside the observed range" do
      dense = HistogramSpec.dense([120.0, 121.0, 122.0])
      dense.percentile(0.1).should be >= dense.minimum
      dense.percentile(100.0).should be <= dense.maximum
    end

    it "computes the sample standard deviation" do
      HistogramSpec.dense([10.0, 20.0, 30.0]).stdev.should be_close(10.0, 1e-9)
    end

    it "reports a zero standard deviation for fewer than two values" do
      HistogramSpec.dense([42.0] of Float64).stdev.should eq(0.0)
      Cryload::Histogram::Dense.new.stdev.should eq(0.0)
    end

    it "keeps the sample standard deviation stable across batching" do
      values = HistogramSpec.sample_values(500)
      mean = values.sum / values.size
      expected = Math.sqrt(values.sum { |value| (value - mean) ** 2 } / (values.size - 1))

      HistogramSpec.dense(values, 13).stdev.should be_close(expected, 1e-6)
    end

    it "reports avg, minimum and maximum from the recorded values" do
      dense = HistogramSpec.dense([5.0, 15.0, 25.0, 35.0], 2)
      dense.avg.should be_close(20.0, 1e-9)
      dense.minimum.should eq(5.0)
      dense.maximum.should eq(35.0)
    end

    describe "#linear_bins" do
      it "splits the observed range into the requested number of bins" do
        dense = HistogramSpec.dense((1..100).map(&.to_f))
        bins = dense.linear_bins(5)

        bins.size.should eq(5)
        bins.sum(&.count).should eq(100)
        bins.first.start_ms.should eq(dense.minimum)
        bins.last.end_ms.should eq(dense.maximum)
        bins.sum(&.percent).should be_close(100.0, 0.05)
      end

      it "produces contiguous, ascending bins" do
        bins = HistogramSpec.dense((1..100).map(&.to_f)).linear_bins(5)
        bins.each_cons_pair do |left, right|
          right.start_ms.should eq(left.end_ms)
          right.start_ms.should be > left.start_ms
        end
      end

      it "collapses to a single full bin when every value lands in one bucket" do
        dense = HistogramSpec.dense([10.0, 10.0, 10.0])
        bins = dense.linear_bins(5)

        bins.size.should eq(1)
        bins.first.count.should eq(3)
        bins.first.percent.should eq(100.0)
        bins.first.start_ms.should eq(10.0)
        bins.first.end_ms.should eq(10.0)
      end
    end
  end
end
