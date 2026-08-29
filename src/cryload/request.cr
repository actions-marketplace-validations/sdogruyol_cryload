module Cryload
  # Everything about a request that is identical for every worker, built once
  # and shared read-only. Keeps the hot path free of a dozen forwarded
  # arguments and makes what is shared across threads explicit.
  struct RequestSpec
    getter method : String
    getter body : String?
    getter timeouts : Timeouts
    getter? insecure : Bool
    getter? follow_redirects : Bool
    getter proxy : URI?

    def initialize(
      @method : String,
      @body : String? = nil,
      @timeouts : Timeouts = Timeouts.new,
      @insecure : Bool = false,
      @follow_redirects : Bool = false,
      @proxy : URI? = nil,
    )
    end
  end

  # One measured HTTP request, including any redirect hops it followed.
  #
  # The response body is streamed through a caller-owned scratch buffer instead
  # of being materialised as a String. That removes a per-request allocation
  # proportional to the response size and is what makes time-to-first-byte
  # observable at all: the block form of `HTTP::Client#exec` hands the response
  # over as soon as the status line and headers are parsed.
  class Request
    REDIRECT_STATUS_CODES = {301, 302, 303, 307, 308}
    DRAIN_BUFFER_SIZE     = 32 * 1024

    getter status_code : Int32
    getter response_bytes : Int64
    getter total_ms : Float64
    getter ttfb_ms : Float64
    getter send_delay_ms : Float64
    getter corrected_ms : Float64
    getter dns_ms : Float64?
    getter connect_ms : Float64?
    getter tls_ms : Float64?

    def self.buffer : Bytes
      Bytes.new(DRAIN_BUFFER_SIZE)
    end

    def initialize(
      client : PhasedClient,
      uri : URI,
      spec : RequestSpec,
      headers : HTTP::Headers,
      buffer : Bytes,
      scheduled_at : Time::Instant? = nil,
    )
      connections_before = client.connections_opened
      start_time = Time.instant
      deadline = spec.timeouts.deadline_from(start_time)

      hop = exec_chain client, uri, spec, headers, buffer, deadline
      end_time = Time.instant

      @status_code = hop.status_code
      @response_bytes = hop.response_bytes
      @ttfb_ms = hop.ttfb_ms
      @total_ms = (end_time - start_time).total_milliseconds

      if scheduled_at
        @send_delay_ms = (start_time - scheduled_at).total_milliseconds
        @corrected_ms = (end_time - scheduled_at).total_milliseconds
      else
        @send_delay_ms = 0.0
        @corrected_ms = @total_ms
      end

      # Phase timings belong to the connection, not the request: with keep-alive
      # only the request that opened the connection reports them.
      if client.connections_opened > connections_before
        @dns_ms = client.last_dns_ms
        @connect_ms = client.last_connect_ms
        @tls_ms = client.last_tls_ms
      else
        @dns_ms = nil
        @connect_ms = nil
        @tls_ms = nil
      end
    end

    record Hop,
      status_code : Int32,
      location : String?,
      response_bytes : Int64,
      ttfb_ms : Float64

    private def exec_chain(client, uri : URI, spec : RequestSpec, headers : HTTP::Headers, buffer : Bytes, deadline : Deadline?) : Hop
      current_client = client
      current_uri = uri
      current_method = spec.method
      current_body = spec.body
      redirects_remaining = Cryload::DEFAULT_MAX_REDIRECTS
      owned_clients = [] of PhasedClient

      begin
        loop do
          hop = exec_hop current_client, current_uri, current_method, current_body, headers, spec, buffer, deadline

          location = hop.location
          unless spec.follow_redirects? && REDIRECT_STATUS_CODES.includes?(hop.status_code) && redirects_remaining > 0 && location
            return hop
          end

          next_uri = resolve_redirect_uri(current_uri, location)
          redirects_remaining -= 1

          if {301, 302, 303}.includes?(hop.status_code) && current_method != "HEAD"
            current_method = "GET"
            current_body = nil
          end

          unless same_origin?(current_uri, next_uri)
            owned_clients << Cryload.create_http_client(next_uri, spec.timeouts, spec.insecure?, spec.proxy)
            current_client = owned_clients.last
          end

          current_uri = next_uri
        end
      ensure
        owned_clients.each(&.close)
      end
    end

    private def exec_hop(client, uri : URI, method : String, body : String?, headers : HTTP::Headers, spec : RequestSpec, buffer : Bytes, deadline : Deadline?) : Hop
      deadline.try { |limit| raise RequestTimeoutError.new(limit.span) if limit.exceeded? }

      request = HTTP::Request.new(method, request_target(uri, spec), headers, body)
      sent_at = Time.instant
      hop = nil

      client.exec(request) do |response|
        ttfb_ms = (Time.instant - sent_at).total_milliseconds
        bytes = drain_body response.body_io?, buffer, deadline, spec
        hop = Hop.new(
          status_code: response.status_code,
          location: response.headers["Location"]?,
          response_bytes: bytes,
          ttfb_ms: ttfb_ms,
        )
      end

      hop || raise IO::EOFError.new("Unexpected end of http response")
    end

    # Counting bytes through a reused buffer also gives --request-timeout a
    # place to fire: a peer trickling a body a few bytes at a time never trips
    # the per-read socket timeout, so only a total deadline can stop it.
    private def drain_body(body_io : IO?, buffer : Bytes, deadline : Deadline?, spec : RequestSpec) : Int64
      return 0_i64 unless body_io

      total = 0_i64
      loop do
        read = body_io.read(buffer)
        break if read == 0
        total += read
        deadline.try { |limit| raise RequestTimeoutError.new(limit.span) if limit.exceeded? }
      end
      total
    end

    private def request_target(uri : URI, spec : RequestSpec) : String
      if spec.proxy && uri.scheme == "http"
        Cryload.proxy_request_target(uri)
      else
        uri.request_target
      end
    end

    private def same_origin?(left : URI, right : URI)
      left.scheme == right.scheme &&
        left.host == right.host &&
        Cryload.effective_port(left) == Cryload.effective_port(right)
    end

    private def resolve_redirect_uri(current_uri : URI, location : String)
      redirect_uri = URI.parse(location)
      return redirect_uri if redirect_uri.host && redirect_uri.scheme

      URI.new(
        scheme: current_uri.scheme,
        host: current_uri.host,
        port: current_uri.port,
        path: resolve_redirect_path(current_uri, redirect_uri.path),
        query: redirect_uri.query,
      )
    end

    private def resolve_redirect_path(current_uri : URI, redirect_path : String)
      return redirect_path if redirect_path.starts_with?("/")
      return current_uri.path.presence || "/" if redirect_path.empty?

      base_path = current_uri.path
      base_segments = (base_path.empty? ? "/" : base_path).split("/")
      base_segments.pop unless base_path.ends_with?("/")

      redirect_path.split("/").each do |segment|
        next if segment.empty? || segment == "."
        if segment == ".."
          base_segments.pop if base_segments.size > 1
        else
          base_segments << segment
        end
      end

      resolved = base_segments.join("/")
      resolved = "/#{resolved}" unless resolved.starts_with?("/")
      resolved.empty? ? "/" : resolved
    end
  end
end
