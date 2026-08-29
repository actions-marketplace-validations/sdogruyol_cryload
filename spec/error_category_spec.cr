require "./spec_helper"

# Every case is built from a real exception instance rather than a stub, because
# the mapping is driven by the concrete class hierarchy plus the message text.
module ErrorCategorySpec
  extend self

  CONNECT_FAMILY = [
    Cryload::ErrorCategory::CONNECT_REFUSED,
    Cryload::ErrorCategory::CONNECT_TIMEOUT,
    Cryload::ErrorCategory::CONNECT_FAILED,
  ]

  def of(ex : Exception) : String
    Cryload::ErrorCategory.of(ex)
  end

  # Built straight from the resolver error code so the spec stays offline and is
  # not at the mercy of an NXDOMAIN-hijacking resolver.
  def dns_error : Socket::Addrinfo::Error
    Socket::Addrinfo::Error.from_os_error(
      nil, Errno.new(LibC::EAI_NONAME),
      domain: "cryload.invalid", type: nil, service: nil, protocol: nil,
    )
  end

  # A port that was bound and released is known to be free, which makes the
  # refusal deterministic instead of depending on an unused-port guess.
  def free_local_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end
end

describe Cryload::ErrorCategory do
  it "maps a request-timeout breach to request_timeout" do
    ErrorCategorySpec.of(Cryload::RequestTimeoutError.new(2.seconds)).should eq("request_timeout")
  end

  it "maps an unexpected end of stream to connection_closed" do
    ErrorCategorySpec.of(IO::EOFError.new).should eq("connection_closed")
  end

  it "defaults a directionless IO timeout to read_timeout" do
    ErrorCategorySpec.of(IO::TimeoutError.new("read timed out")).should eq("read_timeout")
  end

  it "maps an IO timeout that names a write to write_timeout" do
    ErrorCategorySpec.of(IO::TimeoutError.new("write operation timed out")).should eq("write_timeout")
  end

  it "maps a refused connect to connect_refused" do
    ErrorCategorySpec.of(Socket::ConnectError.new("Error connecting: Connection refused")).should eq("connect_refused")
  end

  it "maps a timed-out connect to connect_timeout" do
    ErrorCategorySpec.of(Socket::ConnectError.new("Error connecting to 'host:443': Operation timed out")).should eq("connect_timeout")
    ErrorCategorySpec.of(Socket::ConnectError.new("connect timeout reached")).should eq("connect_timeout")
  end

  it "maps any other connect failure to connect_failed" do
    ErrorCategorySpec.of(Socket::ConnectError.new("Error connecting to 'host:443': Network is unreachable")).should eq("connect_failed")
    ErrorCategorySpec.of(Socket::ConnectError.new).should eq("connect_failed")
  end

  it "prefers connect_timeout over connect_refused when the message says both" do
    ErrorCategorySpec.of(Socket::ConnectError.new("Connection refused after connect timed out")).should eq("connect_timeout")
  end

  it "maps a name resolution failure to dns_failure" do
    ErrorCategorySpec.of(ErrorCategorySpec.dns_error).should eq("dns_failure")
  end

  it "maps a proxy tunnel failure to proxy_error" do
    ErrorCategorySpec.of(IO::Error.new("Proxy CONNECT failed with status 407")).should eq("proxy_error")
  end

  it "maps a peer reset to connection_reset" do
    ErrorCategorySpec.of(IO::Error.new("Connection reset by peer")).should eq("connection_reset")
    ErrorCategorySpec.of(IO::Error.new("Broken pipe (os error 32)")).should eq("connection_reset")
  end

  it "maps a closed socket to connection_closed" do
    ErrorCategorySpec.of(IO::Error.new("Closed stream")).should eq("connection_closed")
  end

  it "maps a malformed response to protocol_error" do
    ErrorCategorySpec.of(IO::Error.new("Invalid HTTP status line")).should eq("protocol_error")
    ErrorCategorySpec.of(IO::Error.new("Invalid chunked encoding")).should eq("protocol_error")
  end

  it "maps an unrecognised IO failure to other" do
    ErrorCategorySpec.of(IO::Error.new("something unhelpful")).should eq("other")
  end

  it "maps a non-transport exception to other" do
    ErrorCategorySpec.of(Exception.new("boom")).should eq("other")
  end

  it "only ever returns a member of the documented vocabulary" do
    samples = [
      Cryload::RequestTimeoutError.new(1.second),
      ErrorCategorySpec.dns_error,
      IO::EOFError.new,
      IO::TimeoutError.new("read timed out"),
      IO::TimeoutError.new("write timed out"),
      Socket::ConnectError.new("Connection refused"),
      Socket::ConnectError.new("Operation timed out"),
      Socket::ConnectError.new("No route to host"),
      IO::Error.new("Proxy CONNECT failed with status 502"),
      IO::Error.new("Connection reset by peer"),
      IO::Error.new("Closed stream"),
      IO::Error.new("Invalid HTTP response"),
      IO::Error.new("mystery"),
      Exception.new("boom"),
    ] of Exception

    samples.each do |ex|
      Cryload::ErrorCategory::ALL.should contain(ErrorCategorySpec.of(ex))
    end
  end

  it "classifies a real refused connection into the connect family" do
    port = ErrorCategorySpec.free_local_port

    ex = begin
      TCPSocket.new("127.0.0.1", port, connect_timeout: 2.seconds).close
      nil
    rescue error : IO::Error
      error
    end

    failure = ex.should_not be_nil
    ErrorCategorySpec::CONNECT_FAMILY.should contain(ErrorCategorySpec.of(failure))
  end
end
