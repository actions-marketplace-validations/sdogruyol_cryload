require "./spec_helper"

describe Cryload::RateLimiter do
  it "spaces requests according to the configured rate" do
    limiter = Cryload::RateLimiter.new(10.0)
    started_at = Time.instant

    3.times { limiter.acquire.should_not be_nil }

    elapsed = (Time.instant - started_at).total_seconds
    elapsed.should be >= 0.15
    elapsed.should be < 0.5
  end

  it "returns the scheduled instant rather than the send instant" do
    reference = Time.instant
    limiter = Cryload::RateLimiter.new(100.0, reference)

    first = limiter.acquire.should_not be_nil
    second = limiter.acquire.should_not be_nil

    (first - reference).total_milliseconds.should be_close(0.0, 1.0)
    (second - first).total_milliseconds.should be_close(10.0, 1.0)
  end

  it "stops acquiring once the schedule runs past the deadline" do
    limiter = Cryload::RateLimiter.new(1.0)
    deadline = Time.instant + 50.milliseconds

    limiter.acquire(deadline).should_not be_nil
    limiter.acquire(deadline).should be_nil
  end

  # The v5 limiter clamped the next slot to "now", so a stalled target erased
  # the slots it had delayed: the run silently issued fewer requests than asked
  # for and the outage never reached the percentiles. The schedule must keep
  # accruing while nobody is acquiring.
  it "keeps accruing the schedule while workers are blocked" do
    reference = Time.instant
    limiter = Cryload::RateLimiter.new(1000.0, reference)

    limiter.acquire.should_not be_nil
    sleep 100.milliseconds

    # Slot 2 is due 1 ms after the reference, i.e. ~99 ms in the past. It must
    # still be handed out at its scheduled time so the backlog is measurable as
    # send delay instead of vanishing.
    scheduled = limiter.acquire.should_not be_nil
    (scheduled - reference).total_milliseconds.should be_close(1.0, 0.5)

    send_delay = (Time.instant - scheduled).total_milliseconds
    send_delay.should be >= 90.0
  end

  it "hands out every slot in the window exactly once across concurrent workers" do
    reference = Time.instant
    limiter = Cryload::RateLimiter.new(1000.0, reference)
    deadline = reference + 200.milliseconds
    counter = Atomic(Int32).new(0)
    done = Channel(Nil).new

    4.times do
      spawn do
        while limiter.acquire(deadline)
          counter.add(1)
        end
        done.send nil
      end
    end

    4.times { done.receive }

    # 200 ms at 1000 req/s is 200 slots, regardless of how the four workers
    # divided them up.
    counter.get.should eq(200)
  end

  describe ".scheduled_count" do
    it "counts the slot at offset zero" do
      Cryload::RateLimiter.scheduled_count(500.0, 5.seconds).should eq(2500)
      Cryload::RateLimiter.scheduled_count(0.5, 1500.milliseconds).should eq(1)
      Cryload::RateLimiter.scheduled_count(10.0, Time::Span.zero).should eq(0)
    end
  end
end
