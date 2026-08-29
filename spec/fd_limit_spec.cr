require "./spec_helper"

# The module only inspects rlimits on POSIX hosts; elsewhere `ensure` compiles
# down to `nil` and there is no observable contract to defend.
{% if flag?(:unix) %}
  describe Cryload::FdLimit do
    it "accepts a single connection" do
      Cryload::FdLimit.ensure(1).should be_nil
    end

    it "refuses a connection count no rlimit can satisfy and explains how to fix it" do
      connections = Int32::MAX // 2
      message = Cryload::FdLimit.ensure(connections)

      text = message.should_not be_nil

      # Names the shortfall in the units the operator has to act on.
      text.should contain("Open file limit too low")
      text.should contain((connections.to_u64 + Cryload::FdLimit::HEADROOM).to_s)
      text.should contain(connections.to_s)

      # Actionable advice, on its own line(s), pointing at the flag to lower.
      text.lines.size.should be > 1
      text.should contain("-c")
      text.should contain("ulimit")
    end

    it "leaves the process able to open sockets after a rejected request" do
      Cryload::FdLimit.ensure(Int32::MAX // 2)
      server = TCPServer.new("127.0.0.1", 0)
      server.local_address.port.should be > 0
      server.close
    end
  end
{% end %}
