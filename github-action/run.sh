#!/usr/bin/env sh
# Builds the cryload argv from the INPUT_* environment variables exported by
# action.yml and runs the benchmark. The argv is assembled with `set --`
# (never eval), so input values are passed through verbatim and cannot be
# split or interpreted by the shell.
#
# Outputs are written to $GITHUB_OUTPUT *before* exiting with cryload's own
# exit code: a threshold breach (--max-p99 etc.) still fails the step, while
# `if: always()` follow-up steps can consume the outputs.
set -eu

fail() {
  echo "cryload-action: $*" >&2
  exit 1
}

[ -n "${INPUT_URL:-}" ] || fail "the 'url' input is required"
command -v cryload >/dev/null 2>&1 || fail "cryload not found on PATH (install step did not run?)"

set -- "$INPUT_URL"

if [ -n "${INPUT_REQUESTS:-}" ]; then set -- "$@" -n "$INPUT_REQUESTS"; fi
if [ -n "${INPUT_DURATION:-}" ]; then set -- "$@" -d "$INPUT_DURATION"; fi
if [ -n "${INPUT_CONNECTIONS:-}" ]; then set -- "$@" -c "$INPUT_CONNECTIONS"; fi
if [ -n "${INPUT_METHOD:-}" ]; then set -- "$@" -m "$INPUT_METHOD"; fi
if [ -n "${INPUT_BODY:-}" ]; then set -- "$@" -b "$INPUT_BODY"; fi
if [ -n "${INPUT_BASIC_AUTH:-}" ]; then set -- "$@" -a "$INPUT_BASIC_AUTH"; fi
if [ -n "${INPUT_TIMEOUT:-}" ]; then set -- "$@" --timeout "$INPUT_TIMEOUT"; fi
if [ -n "${INPUT_RATE:-}" ]; then set -- "$@" -q "$INPUT_RATE"; fi
if [ -n "${INPUT_WARMUP:-}" ]; then set -- "$@" --warmup "$INPUT_WARMUP"; fi
if [ -n "${INPUT_SUCCESS_STATUS:-}" ]; then set -- "$@" --success-status "$INPUT_SUCCESS_STATUS"; fi
if [ -n "${INPUT_USER_AGENT:-}" ]; then set -- "$@" --user-agent "$INPUT_USER_AGENT"; fi
if [ -n "${INPUT_HOST_HEADER:-}" ]; then set -- "$@" --host-header "$INPUT_HOST_HEADER"; fi
if [ -n "${INPUT_PROXY:-}" ]; then set -- "$@" --proxy "$INPUT_PROXY"; fi
if [ -n "${INPUT_MAX_FAIL_RATE:-}" ]; then set -- "$@" --max-fail-rate "$INPUT_MAX_FAIL_RATE"; fi
if [ -n "${INPUT_MAX_P99:-}" ]; then set -- "$@" --max-p99 "$INPUT_MAX_P99"; fi

if [ "${INPUT_FOLLOW_REDIRECTS:-false}" = "true" ]; then set -- "$@" --follow-redirects; fi
if [ "${INPUT_DISABLE_KEEPALIVE:-false}" = "true" ]; then set -- "$@" --disable-keepalive; fi
if [ "${INPUT_INSECURE:-false}" = "true" ]; then set -- "$@" --insecure; fi
if [ "${INPUT_FAIL_ON_ERROR:-false}" = "true" ]; then set -- "$@" --fail-on-error; fi
if [ "${INPUT_FAIL_ON_TRANSPORT_ERROR:-false}" = "true" ]; then set -- "$@" --fail-on-transport-error; fi

# headers/cookies are multiline inputs: one `Key: Value` / `name=value` per
# line, mapped to the repeatable -H / --cookie flags. The heredoc keeps the
# loop in the current shell so `set --` mutations survive it.
if [ -n "${INPUT_HEADERS:-}" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" -H "$line"
  done <<EOF
$INPUT_HEADERS
EOF
fi

if [ -n "${INPUT_COOKIES:-}" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" --cookie "$line"
  done <<EOF
$INPUT_COOKIES
EOF
fi

output_format="${INPUT_OUTPUT_FORMAT:-json}"
set -- "$@" --output-format "$output_format" --no-progress

report="${RUNNER_TEMP:-$(mktemp -d)}/cryload-report.out"

# Capture stdout to a file instead of piping through tee: POSIX sh has no
# pipefail, and we need cryload's exit code, not the pipe tail's.
exit_code=0
cryload "$@" > "$report" || exit_code=$?
cat "$report"

github_output="${GITHUB_OUTPUT:-/dev/null}"
echo "exit_code=${exit_code}" >> "$github_output"

# Structured outputs only exist for JSON reports; the jq guard also skips
# them when cryload failed before producing a report (e.g. invalid flags).
if [ "$output_format" = "json" ] && jq -e . "$report" >/dev/null 2>&1; then
  {
    echo "json=$(jq -c . "$report")"
    echo "requests=$(jq -r '.summary.requests' "$report")"
    echo "requests_per_second=$(jq -r '.summary.requests_per_second' "$report")"
    echo "failure_rate_percent=$(jq -r '.summary.failure_rate_percent' "$report")"
    echo "p50=$(jq -r '.latency_ms.p50' "$report")"
    echo "p99=$(jq -r '.latency_ms.p99' "$report")"
  } >> "$github_output"
fi

exit "$exit_code"
