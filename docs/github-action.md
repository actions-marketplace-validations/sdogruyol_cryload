# GitHub Action reference

Run cryload as a GitHub Action with pass/fail thresholds and JSON results as step outputs:

```yaml
- name: Latency SLA
  uses: sdogruyol/cryload@v5
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
| `sdogruyol/cryload@v5.2.0` | That exact release (reproducible) |
| `sdogruyol/cryload@v5` | Latest release |
| branch / commit SHA | Latest release |

Set the `version` input to override, e.g. `version: v5.2.0`.

## Inputs

All inputs map 1:1 to CLI flags — see `cryload --help` for full semantics.

| Input | CLI flag | Default | Description |
|-------|----------|---------|-------------|
| `url` | positional | *(required)* | Target URL to load test |
| `requests` | `-n` | | Number of requests |
| `duration` | `-d` | | Test duration in seconds (instead of `requests`) |
| `connections` | `-c` | | Concurrent connections (CLI default: 10) |
| `method` | `-m` | | HTTP method |
| `body` | `-b` | | Request body |
| `headers` | `-H` | | One `Key: Value` per line |
| `cookies` | `--cookie` | | One `name=value` per line |
| `basic_auth` | `-a` | | `user:password` |
| `timeout` | `--timeout` | | Connect/read timeout in seconds |
| `rate` | `-q` | | Rate limit in requests/sec |
| `warmup` | `--warmup` | | Warmup seconds before the benchmark |
| `follow_redirects` | `-L` | `false` | Follow redirects |
| `disable_keepalive` | `--disable-keepalive` | `false` | New connection per request |
| `insecure` | `--insecure` | `false` | Accept invalid TLS certificates |
| `success_status` | `--success-status` | | Success codes/ranges, e.g. `200-299,301` |
| `user_agent` | `--user-agent` | | User-Agent header |
| `host_header` | `--host-header` | | Host header override |
| `proxy` | `--proxy` | | HTTP(S) proxy URL |
| `fail_on_error` | `--fail-on-error` | `false` | Fail on any HTTP/transport error |
| `fail_on_transport_error` | `--fail-on-transport-error` | `false` | Fail on any transport error |
| `max_fail_rate` | `--max-fail-rate` | | Fail when failure rate exceeds this % |
| `max_p99` | `--max-p99` | | Fail when p99 exceeds this many ms |
| `output_format` | `--output-format` | `json` | `text`, `json`, `csv`, `quiet` |
| `version` | | | Release tag to install (overrides the action ref) |

File-based flags (`--body-file`, `--body-stdin`, `--urls-file`, `--random-path`) are not exposed as inputs. The action puts `cryload` on `PATH`, so follow-up `run:` steps can use the full CLI directly.

## Outputs

Structured outputs are populated when `output_format` is `json` (the default) — field names match the [JSON output reference](json-output.md).

| Output | Source | Description |
|--------|--------|-------------|
| `json` | full report | Compact single-line JSON document |
| `requests` | `.summary.requests` | Total attempts |
| `requests_per_second` | `.summary.requests_per_second` | Throughput |
| `failure_rate_percent` | `.summary.failure_rate_percent` | Failure rate |
| `p50` | `.latency_ms.p50` | Median latency (ms) |
| `p99` | `.latency_ms.p99` | p99 latency (ms) |
| `exit_code` | | cryload's exit code (`1` on threshold breach) |

When a threshold breaks, the step fails with cryload's exit code — but outputs are written first, so `if: always()` steps can still consume them.

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
        uses: sdogruyol/cryload@v5
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
