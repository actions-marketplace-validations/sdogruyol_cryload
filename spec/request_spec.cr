require "./spec_helper"
require "./support/test_server"

module RequestSpecHelper
  extend self

  def perform_request(
    port,
    path,
    method = "GET",
    body : String? = nil,
    follow_redirects = false,
    timeouts : Cryload::Timeouts = Cryload::Timeouts.new,
    scheduled_at : Time::Instant? = nil,
  )
    uri = URI.parse("http://127.0.0.1:#{port}#{path}")
    client = Cryload.create_http_client(uri, timeouts)
    spec = Cryload::RequestSpec.new(
      method: method,
      body: body,
      timeouts: timeouts,
      follow_redirects: follow_redirects,
    )
    begin
      Cryload::Request.new client, uri, spec, HTTP::Headers.new, Cryload::Request.buffer, scheduled_at
    ensure
      client.close
    end
  end
end

describe Cryload::Request do
  it "measures total time, time to first byte and the connection phases" do
    server, port = TestServer.start do |context|
      context.response.print "hello"
    end

    request = RequestSpecHelper.perform_request(port, "/")
    server.close

    request.status_code.should eq(200)
    request.response_bytes.should eq(5)
    request.total_ms.should be > 0.0
    request.ttfb_ms.should be > 0.0
    request.ttfb_ms.should be <= request.total_ms + 0.5

    # First request on a fresh client opens the connection, so it owns the
    # phase timings. Plain HTTP performs no handshake, so tls_ms stays nil
    # rather than reporting a zero-millisecond one.
    request.dns_ms.should_not be_nil
    request.connect_ms.should_not be_nil
    request.tls_ms.should be_nil
  end

  it "attributes connection phases only to the request that opened the connection" do
    server, port = TestServer.start do |context|
      context.response.print "ok"
    end

    uri = URI.parse("http://127.0.0.1:#{port}/")
    client = Cryload.create_http_client(uri)
    spec = Cryload::RequestSpec.new(method: "GET")
    buffer = Cryload::Request.buffer

    first = Cryload::Request.new(client, uri, spec, HTTP::Headers.new, buffer)
    second = Cryload::Request.new(client, uri, spec, HTTP::Headers.new, buffer)
    client.close
    server.close

    first.connect_ms.should_not be_nil
    second.connect_ms.should be_nil
    client.connections_opened.should eq(1)
  end

  it "counts response bytes without materialising the body" do
    payload = "x" * 200_000
    server, port = TestServer.start do |context|
      context.response.print payload
    end

    request = RequestSpecHelper.perform_request(port, "/")
    server.close

    request.response_bytes.should eq(payload.bytesize)
  end

  it "reports zero send delay when there is no schedule" do
    server, port = TestServer.start(&.response.print("ok"))

    request = RequestSpecHelper.perform_request(port, "/")
    server.close

    request.send_delay_ms.should eq(0.0)
    request.corrected_ms.should eq(request.total_ms)
  end

  # Corrected latency is measured from the instant the request was *scheduled*
  # for, so time spent waiting for a free worker counts against the target.
  it "adds the wait since the scheduled send time to corrected latency" do
    server, port = TestServer.start(&.response.print("ok"))

    scheduled_at = Time.instant - 250.milliseconds
    request = RequestSpecHelper.perform_request(port, "/", scheduled_at: scheduled_at)
    server.close

    request.send_delay_ms.should be_close(250.0, 50.0)
    request.corrected_ms.should be_close(request.send_delay_ms + request.total_ms, 1.0)
    request.total_ms.should be < 100.0
  end

  it "aborts a slow-trickle response once the request deadline passes" do
    server, port = TestServer.start do |context|
      context.response.headers["Content-Length"] = "20"
      20.times do
        context.response.print "x"
        context.response.flush
        sleep 100.milliseconds
      end
    end

    # Each individual read lands well inside the 5s socket timeout, so only the
    # total deadline can stop this.
    timeouts = Cryload::Timeouts.new(timeout: 5.seconds, request_timeout: 300.milliseconds)

    expect_raises(Cryload::RequestTimeoutError, /request-timeout/) do
      RequestSpecHelper.perform_request(port, "/", timeouts: timeouts)
    end

    server.close
  end

  it "lets the same response through when only the socket timeout is set" do
    server, port = TestServer.start do |context|
      context.response.headers["Content-Length"] = "5"
      5.times do
        context.response.print "x"
        context.response.flush
        sleep 100.milliseconds
      end
    end

    request = RequestSpecHelper.perform_request(port, "/", timeouts: Cryload::Timeouts.new(timeout: 5.seconds))
    server.close

    request.status_code.should eq(200)
    request.response_bytes.should eq(5)
    request.total_ms.should be > 400.0
  end

  it "resolves relative redirect paths with parent segments" do
    seen_paths = [] of String
    server, port = TestServer.start do |context|
      seen_paths << context.request.path
      case context.request.path
      when "/api/v1/start"
        context.response.status_code = 302
        context.response.headers["Location"] = "../v2/final"
      else
        context.response.status_code = 200
        context.response.print "OK"
      end
    end

    request = RequestSpecHelper.perform_request(port, "/api/v1/start", follow_redirects: true)
    server.close

    request.status_code.should eq(200)
    seen_paths.should contain("/api/v2/final")
  end

  it "resolves sibling relative redirect paths" do
    seen_paths = [] of String
    server, port = TestServer.start do |context|
      seen_paths << context.request.path
      case context.request.path
      when "/files/current/doc"
        context.response.status_code = 302
        context.response.headers["Location"] = "other.txt"
      else
        context.response.status_code = 200
        context.response.print "OK"
      end
    end

    request = RequestSpecHelper.perform_request(port, "/files/current/doc", follow_redirects: true)
    server.close

    request.status_code.should eq(200)
    seen_paths.should contain("/files/current/other.txt")
  end

  it "converts POST to GET after a 302 redirect" do
    methods = [] of String
    server, port = TestServer.start do |context|
      methods << context.request.method
      case context.request.path
      when "/post"
        context.response.status_code = 302
        context.response.headers["Location"] = "/target"
      else
        context.response.status_code = 200
        context.response.print context.request.method
      end
    end

    request = RequestSpecHelper.perform_request(port, "/post", "POST", "payload", follow_redirects: true)
    server.close

    request.status_code.should eq(200)
    methods.should eq(["POST", "GET"])
  end

  it "stops following redirects after the configured maximum" do
    server, port = TestServer.start do |context|
      hop = (context.request.query || "n=0").split("=").last.to_i
      if hop < Cryload::DEFAULT_MAX_REDIRECTS + 1
        context.response.status_code = 302
        context.response.headers["Location"] = "/hop?n=#{hop + 1}"
      else
        context.response.status_code = 200
        context.response.print "done"
      end
    end

    request = RequestSpecHelper.perform_request(port, "/hop?n=0", follow_redirects: true)
    server.close

    request.status_code.should eq(302)
  end

  it "follows absolute redirect locations on the same host" do
    seen_paths = [] of String
    redirect_port = 0
    server = HTTP::Server.new do |context|
      seen_paths << context.request.path
      case context.request.path
      when "/start"
        context.response.status_code = 307
        context.response.headers["Location"] = "http://127.0.0.1:#{redirect_port}/absolute"
      else
        context.response.status_code = 200
        context.response.print "OK"
      end
    end
    address = server.bind_unused_port
    redirect_port = address.port
    spawn { server.listen }
    sleep 50.milliseconds

    request = RequestSpecHelper.perform_request(redirect_port, "/start", follow_redirects: true)
    server.close

    request.status_code.should eq(200)
    seen_paths.should contain("/absolute")
  end

  it "reuses a keep-alive client across requests and reconnects after a close" do
    server, port = TestServer.start do |context|
      context.response.headers["Connection"] = "close" if context.request.path == "/close"
      context.response.print "ok"
    end

    uri = URI.parse("http://127.0.0.1:#{port}/")
    close_uri = URI.parse("http://127.0.0.1:#{port}/close")
    client = Cryload.create_http_client(uri)
    spec = Cryload::RequestSpec.new(method: "GET")
    buffer = Cryload::Request.buffer

    Cryload::Request.new(client, uri, spec, HTTP::Headers.new, buffer)
    Cryload::Request.new(client, close_uri, spec, HTTP::Headers.new, buffer)
    # The server hung up, so this must transparently open a second connection
    # rather than fail. Handing a pre-connected socket to HTTP::Client would
    # have raised "cannot be reconnected" here.
    reconnected = Cryload::Request.new(client, uri, spec, HTTP::Headers.new, buffer)

    client.close
    server.close

    reconnected.status_code.should eq(200)
    client.connections_opened.should eq(2)
    reconnected.connect_ms.should_not be_nil
  end
end
