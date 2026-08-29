{% if flag?(:unix) %}
  lib LibC
    # Crystal's LibC bindings ship getrlimit but not setrlimit, and raising the
    # soft limit ourselves is what lets `-c 5000` work on a stock shell whose
    # soft limit is 1024 but whose hard limit is far higher.
    fun setrlimit(resource : Int, rlim : Rlimit*) : Int
  end
{% end %}

module Cryload
  # Guards against the most confusing failure mode of a load generator: running
  # out of file descriptors mid-run and reporting a pile of transport errors
  # that look like the target failing.
  module FdLimit
    extend self

    # Sockets plus stdio, DNS, and the report file the caller may be redirecting
    # into. 64 is generous rather than exact on purpose.
    HEADROOM = 64

    # Raises the soft limit toward the hard limit when needed. Returns nil when
    # the process can open `connections` sockets, otherwise an actionable
    # message for the caller to print before exiting with a config error.
    def ensure(connections : Int32) : String?
      {% if flag?(:unix) %}
        required = connections.to_u64 + HEADROOM

        limit = current
        return nil unless limit
        soft, hard = limit
        return nil if soft >= required

        if hard >= required
          return nil if raise_soft_limit(required, hard)
          return "Open file limit too low: #{soft} available, #{required} needed for #{connections} connections.\n" \
                 "  → Raise it with 'ulimit -n #{required}', or lower -c."
        end

        # The hard limit caps what this process can ask for, so no amount of
        # setrlimit help gets us there; say what actually has to change.
        "Open file limit too low: hard limit is #{format_limit(hard)}, #{required} needed for #{connections} connections.\n" \
        "  → Raise the hard limit ('ulimit -Hn #{required}' as root, or LimitNOFILE=#{required} in the systemd unit),\n" \
        "    or lower -c to at most #{hard > HEADROOM ? hard - HEADROOM : 1}."
      {% else %}
        nil
      {% end %}
    end

    {% if flag?(:unix) %}
      private def current : Tuple(UInt64, UInt64)?
        limit = uninitialized LibC::Rlimit
        return nil unless LibC.getrlimit(LibC::RLIMIT_NOFILE, pointerof(limit)) == 0
        {limit.rlim_cur.to_u64, limit.rlim_max.to_u64}
      end

      private def raise_soft_limit(required : UInt64, hard : UInt64) : Bool
        limit = uninitialized LibC::Rlimit
        limit.rlim_cur = typeof(limit.rlim_cur).new(required)
        limit.rlim_max = typeof(limit.rlim_max).new(hard)
        LibC.setrlimit(LibC::RLIMIT_NOFILE, pointerof(limit)) == 0
      end

      private def format_limit(hard : UInt64) : String
        hard == UInt64::MAX ? "unlimited" : hard.to_s
      end
    {% end %}
  end
end
