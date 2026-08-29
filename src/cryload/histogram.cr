module Cryload
  # HDR-style logarithmic histogram: ~1% relative precision from 1µs to 1h in a
  # few thousand buckets instead of a dense linear array.
  #
  # Two representations share the same bucket layout so they can be merged
  # without conversion: `Sparse` is worker-local and lock-free, `Dense` is the
  # global aggregate merged under the `Stats` mutex.
  module Histogram
    MIN_MS       =       0.001
    MAX_MS       = 3_600_000.0
    GROWTH       =        1.01
    LOG_GROWTH   = Math.log(GROWTH)
    BUCKET_COUNT = (Math.log(MAX_MS / MIN_MS) / LOG_GROWTH).ceil.to_i + 1

    def self.bucket_index(value_ms : Float64) : Int32
      return 0 if value_ms <= MIN_MS

      index = (Math.log(value_ms / MIN_MS) / LOG_GROWTH).floor.to_i
      {index, BUCKET_COUNT - 1}.min
    end

    # Geometric midpoint of the bucket, the best estimate for values in it.
    def self.bucket_value(index : Int32) : Float64
      MIN_MS * (GROWTH ** (index + 0.5))
    end

    # One rolled-up linear bin of the text histogram and the JSON report.
    struct Bin
      getter start_ms : Float64
      getter end_ms : Float64
      getter count : Int64
      getter percent : Float64

      def initialize(@start_ms, @end_ms, @count, @percent)
      end
    end

    # Worker-local accumulator. Buckets are sparse because a single worker
    # touches only a handful of them between flushes.
    class Sparse
      getter count : Int64
      getter sum : Float64
      getter min : Float64
      getter max : Float64
      getter mean : Float64
      getter m2 : Float64
      getter buckets : Hash(Int32, Int64)

      def initialize
        @count = 0_i64
        @sum = 0.0
        @min = Float64::INFINITY
        @max = 0.0
        @mean = 0.0
        @m2 = 0.0
        @buckets = Hash(Int32, Int64).new(0_i64)
      end

      def empty? : Bool
        @count == 0
      end

      def record(value_ms : Float64) : Nil
        @count += 1
        @sum += value_ms
        @min = value_ms if value_ms < @min
        @max = value_ms if value_ms > @max

        # Welford, so variance survives batching without keeping samples.
        delta = value_ms - @mean
        @mean += delta / @count
        @m2 += delta * (value_ms - @mean)

        @buckets[Histogram.bucket_index(value_ms)] += 1
      end
    end

    # Global aggregate. Dense buckets keep the merge and the percentile scan
    # branch-free; one instance is ~18 KB.
    class Dense
      getter count : Int64
      getter sum : Float64
      getter min : Float64
      getter max : Float64
      getter mean : Float64
      getter m2 : Float64

      def initialize
        @count = 0_i64
        @sum = 0.0
        @min = Float64::INFINITY
        @max = 0.0
        @mean = 0.0
        @m2 = 0.0
        @buckets = Array(Int64).new(BUCKET_COUNT, 0_i64)
      end

      def empty? : Bool
        @count == 0
      end

      # Chan et al. parallel variance combination, so merging a batch is exact
      # rather than an approximation of the streaming update.
      def merge(other : Sparse) : Nil
        return if other.empty?

        previous = @count
        @count += other.count
        @sum += other.sum
        @min = other.min if other.min < @min
        @max = other.max if other.max > @max

        if previous == 0
          @mean = other.mean
          @m2 = other.m2
        else
          delta = other.mean - @mean
          @mean += delta * other.count / @count
          @m2 += other.m2 + delta * delta * previous * other.count / @count
        end

        other.buckets.each do |index, count|
          @buckets[index] += count
        end
      end

      def avg : Float64
        @count == 0 ? 0.0 : @sum / @count
      end

      def minimum : Float64
        @count == 0 ? 0.0 : @min
      end

      def maximum : Float64
        @count == 0 ? 0.0 : @max
      end

      # Sample standard deviation. v5 divided by n, which understates the spread
      # on small runs.
      def stdev : Float64
        return 0.0 if @count < 2
        Math.sqrt(@m2 / (@count - 1))
      end

      def percentile(percentile : Float64) : Float64
        return 0.0 if @count == 0

        rank = (@count.to_f * (percentile / 100.0)).ceil.to_i64
        rank = 1_i64 if rank < 1
        seen = 0_i64

        @buckets.each_with_index do |count, index|
          next if count == 0
          seen += count
          return Histogram.bucket_value(index).clamp(@min, @max) if seen >= rank
        end

        @max
      end

      # Rolls the logarithmic buckets up into `bin_count` equal-width linear
      # bins.
      def linear_bins(bin_count : Int32 = 11) : Array(Bin)
        bins = [] of Bin
        return bins if @count == 0

        if Histogram.bucket_index(@min) == Histogram.bucket_index(@max)
          bins << Bin.new(@min.round(2), @max.round(2), @count, 100.0)
          return bins
        end

        effective_bin_count = {1, bin_count}.max
        span_ms = @max - @min
        counts = Array(Int64).new(effective_bin_count, 0_i64)

        @buckets.each_with_index do |count, index|
          next if count == 0

          latency_ms = Histogram.bucket_value(index)
          bin_index = (((latency_ms - @min) / span_ms) * effective_bin_count).floor.to_i
          counts[bin_index.clamp(0, effective_bin_count - 1)] += count
        end

        effective_bin_count.times do |index|
          start_ms = @min + (span_ms * index / effective_bin_count)
          end_ms = if index == effective_bin_count - 1
                     @max
                   else
                     @min + (span_ms * (index + 1) / effective_bin_count)
                   end
          bins << Bin.new(
            start_ms.round(2),
            end_ms.round(2),
            counts[index],
            ((counts[index].to_f / @count) * 100.0).round(2),
          )
        end

        bins
      end
    end
  end
end
