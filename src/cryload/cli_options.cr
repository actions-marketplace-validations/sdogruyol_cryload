module Cryload
  class Cli
    # Typed CLI options populated by the option parser. Nilable fields mean
    # "not provided"; booleans default to their flag-absent value.
    class Options
      property server : String?
      property urls_file : String?
      property numbers : Int32?
      property duration : Time::Span?
      property connections : Int32 = 10
      property workers : Int32?
      property method : String = "GET"
      property body : String?
      property body_file : String?
      property? body_stdin : Bool = false
      property headers : Array(String) = [] of String
      property cookies : Array(String) = [] of String
      property user_agent : String?
      property host_header : String?
      property basic_auth : String?
      property timeout : Time::Span?
      property request_timeout : Time::Span?
      property rate : Float64?
      property? follow_redirects : Bool = false
      property? disable_keepalive : Bool = false
      property output_format : String?
      property? json : Bool = false
      property success_status : String?
      property? insecure : Bool = false
      property? fail_on_error : Bool = false
      property? fail_on_transport_error : Bool = false
      property? fail_on_rate_miss : Bool = false
      property? latency_correction : Bool = true
      property max_fail_rate : Float64?
      property min_rps : Float64?
      property max_latency : Hash(Threshold::Metric, Float64) = Hash(Threshold::Metric, Float64).new
      property url_thresholds : Array(String) = [] of String
      property warmup : Time::Span?
      property proxy : String?
      # nil means "decide from the terminal": progress belongs on an interactive
      # stderr, not in a CI log full of carriage returns.
      property progress : Bool?
      property? random_path : Bool = false
    end

    module OptionsBuilder
      extend self

      def resolve_output_format(options : Options) : String
        return "json" if options.json?
        options.output_format || "text"
      end

      def resolve_body(options : Options) : String?
        return options.body if options.body
        return STDIN.gets_to_end if options.body_stdin?
        options.body_file.try { |path| File.read(path) }
      end

      def resolve_progress(options : Options) : Bool
        progress = options.progress
        return progress unless progress.nil?
        STDERR.tty?
      end

      def build_headers(options : Options) : HTTP::Headers
        headers = parse_headers(options.headers)
        if host_header = options.host_header
          headers["Host"] = host_header
        end
        if user_agent = options.user_agent
          headers["User-Agent"] = user_agent
        end
        if auth = options.basic_auth
          headers["Authorization"] = "Basic #{Base64.strict_encode(auth)}"
        end
        unless options.cookies.empty?
          existing = headers["Cookie"]?
          cookie_values = existing ? [existing] + options.cookies : options.cookies
          headers["Cookie"] = cookie_values.join("; ")
        end
        headers
      end

      def build_timeouts(options : Options) : Timeouts
        Timeouts.new(timeout: options.timeout, request_timeout: options.request_timeout)
      end

      def build_ci_thresholds(options : Options) : CiThresholds
        thresholds = [] of Threshold

        options.max_latency.each do |metric, limit|
          thresholds << Threshold.new(metric, limit)
        end
        options.max_fail_rate.try { |limit| thresholds << Threshold.new(Threshold::Metric::FailRate, limit) }
        options.min_rps.try { |limit| thresholds << Threshold.new(Threshold::Metric::Rps, limit) }
        thresholds.concat Validator.parse_url_thresholds(options.url_thresholds)

        CiThresholds.new(
          fail_on_error: options.fail_on_error?,
          fail_on_transport_error: options.fail_on_transport_error?,
          fail_on_rate_miss: options.fail_on_rate_miss?,
          thresholds: thresholds,
        )
      end

      def resolve_urls(options : Options) : Array(URI)
        urls = [] of URI
        if path = options.urls_file
          urls.concat Cryload.load_urls_from_file(path)
        end
        if server = options.server
          urls.unshift URI.parse(server)
        end
        urls
      end

      def resolve_proxy(options : Options) : URI?
        options.proxy.try { |raw| URI.parse(raw) }
      end

      private def parse_headers(raw_headers : Array(String))
        headers = HTTP::Headers.new
        raw_headers.each do |header|
          parts = header.split(":", 2)
          next if parts.size != 2
          key = parts[0].strip
          value = parts[1].strip
          headers[key] = value
        end
        headers
      end
    end
  end
end
