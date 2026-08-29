# GitHub Action reference

Run cryload as a GitHub Action with pass/fail thresholds and JSON results as step outputs:

```yaml
- name: Latency SLA
  uses: sdogruyol/cryload@v6
  with:
    url: http://127.0.0.1:3000/api
    requests: 500
    connections: 50
    max_p99: "250"
```

The action installs the prebuilt release binary and runs it directly on the runner — no container. It works on Linux, macOS, and Windows runners and can reach services listening on the runner's localhost.

> **macOS runners:** Local Network Privacy on macOS 15+ blocks unsigned binaries from reaching loopback addresses, so localhost targets may time out there. Prefer Linux runners for localhost benchmarks.
>
> **Windows runners:** requires cryload v5.2.0 or newer — earlier Windows binaries were dynamically linked against the Crystal toolchain's DLLs and fail to start on clean runners.

## Versioning

The installed binary version follows the ref the action is pinned to:

| `uses:` ref | Installed binary |
|-------------|------------------|
| `sdogruyol/cryload@v6.0.0` | That exact release (reproducible) |
| `sdogruyol/cryload@v6` | Latest release |
| branch / commit SHA | Latest release |

Set the `version` input to override, e.g. `version: v6.0.0`.

## Inputs

All inputs map 1:1 to CLI flags — see `cryload --help` for full semantics.

| Input | CLI flag | Default | Description |
|-------|----------|---------|-------------|
| `url` | positional | *(required)* | Target URL to load test |
| `requests` | `-n` | | Number of requests |
| `duration` | `-d` | | Test duration, e.g. `30`, `30s`, `2m`, `500ms` (instead of `requests`) |
| `connections` | `-c` | | Concurrent connections (CLI default: 10) |
| `workers` | `--workers` | | OS threads running the load fibers (CLI default: `min(cpu_count, connections)`); `1` reproduces single-core behaviour |
| `method` | `-m` | | HTTP method |
| `body` | `-b` | | Request body |
| `headers` | `-H` | | One `Key: Value` per line |
| `cookies` | `--cookie` | | One `name=value` per line |
| `basic_auth` | `-a` | | `user:password` |
| `timeout` | `--timeout` | | Connect/read/write timeout, e.g. `5`, `5s`, `500ms` |
| `request_timeout` | `--request-timeout` | | Total per-request deadline including body download |
| `rate` | `-q` | | Rate limit in requests/sec; fractional allowed (`0.5`) |
| `warmup` | `--warmup` | | Warmup before the timed benchmark, e.g. `5`, `5s` |
| `latency_correction` | `--latency-correction` | `on` | `on` or `off`; `on` gates on coordinated-omission-corrected latency |
| `follow_redirects` | `-L` | `false` | Follow redirects |
| `disable_keepalive` | `--disable-keepalive` | `false` | New connection per request |
| `insecure` | `--insecure` | `false` | Accept invalid TLS certificates |
| `success_status` | `--success-status` | | Success codes/ranges, e.g. `200-299,301` |
| `user_agent` | `--user-agent` | | User-Agent header |
| `host_header` | `--host-header` | | Host header override |
| `proxy` | `--proxy` | | HTTP(S) proxy URL |
| `fail_on_error` | `--fail-on-error` | `false` | Fail on any HTTP/transport error |
| `fail_on_transport_error` | `--fail-on-transport-error` | `false` | Fail on any transport error |
| `fail_on_rate_miss` | `--fail-on-rate-miss` | `false` | Fail when the attained rate is more than 1% below `rate` |
| `max_fail_rate` | `--max-fail-rate` | | Fail when failure rate exceeds this % |
| `max_p50` | `--max-p50` | | Fail when p50 exceeds this many ms |
| `max_p75` | `--max-p75` | | Fail when p75 exceeds this many ms |
| `max_p90` | `--max-p90` | | Fail when p90 exceeds this many ms |
| `max_p95` | `--max-p95` | | Fail when p95 exceeds this many ms |
| `max_p99` | `--max-p99` | | Fail when p99 exceeds this many ms |
| `max_p999` | `--max-p999` | | Fail when p99.9 exceeds this many ms |
| `max_avg` | `--max-avg` | | Fail when average latency exceeds this many ms |
| `max_latency` | `--max-latency` | | Fail when the maximum observed latency exceeds this many ms |
| `min_rps` | `--min-rps` | | Fail when throughput is below this many req/s |
| `url_thresholds` | `--url-threshold` | | Per-endpoint gates, one `PATTERN METRIC VALUE` per line |
| `output_format` | `--output-format` | `json` | `text`, `json`, `csv`, `quiet` |
| `version` | | | Release tag to install (overrides the action ref) |

File-based and generator flags (`--body-file`, `--body-stdin`, `--urls-file`, `--random-path`) are not exposed as inputs. The action puts `cryload` on `PATH`, so follow-up `run:` steps can use the full CLI directly — that is also how you benchmark a list of URLs in one run.

## Outputs

Structured outputs are populated when `output_format` is `json` (the default) — field names match the [JSON output reference](json-output.md).

| Output | Source | Description |
|--------|--------|-------------|
| `json` | full report | Compact single-line JSON document |
| `requests` | `.summary.requests` | Total attempts |
| `requests_per_second` | `.summary.requests_per_second` | Throughput |
| `failure_rate_percent` | `.summary.failure_rate_percent` | Failure rate |
| `p50` | `.latency_ms.p50` | Median latency (ms) |
| `p95` | `.latency_ms.p95` | p95 latency (ms) |
| `p99` | `.latency_ms.p99` | p99 latency (ms) |
| `corrected_p99` | `.corrected_latency_ms.p99` | Coordinated-omission-corrected p99 (ms); equals `p99` when `rate` is unset |
| `rate_attainment_percent` | `.rate.attainment_percent` | Attained rate as a percentage of the requested rate; empty string when `rate` is unset |
| `thresholds_passed` | `.thresholds.passed` | `true` when every configured threshold passed |
| `schema_version` | `.schema_version` | JSON report schema version (`1`) |
| `exit_code` | | cryload's exit code — see [Exit codes](#exit-codes) |

When a threshold breaks, the step fails with cryload's exit code — but outputs are written first, so `if: always()` steps can still consume them.

## Exit codes

cryload's exit code is a taxonomy, not a boolean, so a failing step already says *why* it failed. The same value is published as the `exit_code` output.

| Code | Meaning |
|------|---------|
| `0` | Run finished, no threshold breached |
| `1` | A threshold was breached (`max_*`, `min_rps`, `max_fail_rate`, `fail_on_error`, `fail_on_transport_error`, `fail_on_rate_miss`, `url_thresholds`) |
| `2` | Usage/config error: bad flag, bad URL, missing file, a `url_thresholds` pattern matching no target URL, file-descriptor limit too low |
| `3` | Target unreachable: zero HTTP responses and at least one transport error |
| `130` | Interrupted (SIGINT) |
| `143` | Terminated (SIGTERM) |

A breached threshold takes precedence over a signal code.

Branching on `exit_code` separates a real performance regression (`1`) from a service that never came up (`3`) — two failures that look identical when all you know is "the step failed". `continue-on-error: true` keeps the job alive so the triage step decides the outcome:

```yaml
      - name: Benchmark
        id: bench
        continue-on-error: true
        uses: sdogruyol/cryload@v6
        with:
          url: http://127.0.0.1:3000/api
          duration: 30s
          max_p99: "250"

      - name: Triage
        if: always()
        env:
          CODE: ${{ steps.bench.outputs.exit_code }}
          P99: ${{ steps.bench.outputs.corrected_p99 }}
        run: |
          case "$CODE" in
            0)       echo "within SLA (p99 ${P99} ms)" ;;
            1)       echo "::error::performance regression: p99 ${P99} ms breaches the gate"; exit 1 ;;
            2)       echo "::error::cryload was misconfigured"; exit 1 ;;
            3)       echo "::error::service never became reachable; check the startup step"; exit 1 ;;
            130|143) echo "::error::benchmark was interrupted"; exit 1 ;;
            *)       echo "::error::unexpected cryload exit code ${CODE}"; exit 1 ;;
          esac
```

## Full example

```yaml
jobs:
  load-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start app
        run: |
          docker compose up -d
          curl --retry 10 --retry-connrefused -sf http://127.0.0.1:3000/health

      - name: Benchmark
        id: bench
        uses: sdogruyol/cryload@v6
        with:
          url: http://127.0.0.1:3000/api
          duration: 30
          connections: 50
          warmup: 5
          headers: |
            Authorization: Bearer ${{ secrets.API_TOKEN }}
            Accept: application/json
          max_p99: "250"
          max_fail_rate: "1"

      # Outputs survive a threshold failure; pass them via env, never
      # inline them into the script.
      - name: Report results
        if: always()
        env:
          REPORT: ${{ steps.bench.outputs.json }}
          P99: ${{ steps.bench.outputs.p99 }}
          RPS: ${{ steps.bench.outputs.requests_per_second }}
        run: |
          echo "p99: ${P99} ms, throughput: ${RPS} req/s"
          printf '%s' "$REPORT" | jq .
```

## Per-endpoint gates

`url_thresholds` takes one `PATTERN METRIC VALUE` per line, each mapped to a repeatable `--url-threshold`. `PATTERN` is matched as a substring against the target URLs, so `/api/users` matches `http://127.0.0.1:3000/api/users`. `METRIC` is one of `max-p50`, `max-p75`, `max-p90`, `max-p95`, `max-p99`, `max-p999`, `max-avg`, `max-latency`, `max-fail-rate`, `min-rps`. A pattern that matches no target URL is a config error (exit `2`).

Configuring at least one per-endpoint gate switches on per-URL tracking, so the JSON report carries a `by_url` array even for a single-URL run:

```yaml
      - name: Per-endpoint SLA
        id: bench
        uses: sdogruyol/cryload@v6
        with:
          url: http://127.0.0.1:3000/api/users
          duration: 30s
          connections: 50
          url_thresholds: |
            /api/users max-p99 120
            /api/users max-fail-rate 0.5
          max_p99: "250"
```

Every gate — global and per-URL — shows up in `.thresholds.evaluated`, and `thresholds_passed` is `false` as soon as one of them breaches.

## Multi-core runs

`workers` sets the number of OS threads the load fibers run on, defaulting to `min(cpu_count, connections)` (the CPU count honours `CRYSTAL_WORKERS`). `workers: 1` pins load generation to a single core, which is what you want when comparing against pre-6.0 cryload results:

```yaml
      - name: Saturate the service
        id: bench
        uses: sdogruyol/cryload@v6
        with:
          url: http://127.0.0.1:3000/
          duration: 5s
          connections: 128
          workers: 8
          min_rps: "50000"
```

Derive the `min_rps` gate from a baseline run on the same runner type: GitHub-hosted runners have far fewer cores than a workstation, so both the useful `workers` value and the attainable throughput are much lower there than locally.
