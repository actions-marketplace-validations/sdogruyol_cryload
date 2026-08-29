# cryload comparison
Full feature comparison with other HTTP load testing tools.
| Feature | cryload | [ab](https://httpd.apache.org/docs/current/programs/ab.html) | [hey](https://github.com/rakyll/hey) | [oha](https://github.com/hatoo/oha) | [wrk](https://github.com/wg/wrk) |
|---------|:-------:|:--:|:---:|:---:|:--:|
| Language | Crystal | C | Go | Rust | C |
| **Concurrent** connections (`-c`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Duration** / **request count** (`-n`) | ✅ | ✅ (`-t` / `-n`) | ✅ | ✅ | ✅ |
| **JSON** / **CSV** / quiet output for **CI/CD** | ✅ | — (text) | JSON | JSON | — (text / Lua) |
| **CI thresholds** via exit codes (`--max-p99`, `--fail-on-error`) | ✅ | — | — | — | — |
| **Per-endpoint** threshold gates (`--url-threshold`) | ✅ | — | — | — | — |
| **Exit code taxonomy** (0/1/2/3/130/143) | ✅ | — | — | — | — |
| **Coordinated-omission correction** | ✅ | — | — | — | — |
| **Latency phase breakdown** (DNS/connect/TLS/TTFB) | ✅ | — | partial | partial | — |
| **Per-URL** / **per-status** breakdown | ✅ | — | — | — | — |
| Text latency **histogram** + distribution | ✅ | basic | limited | TUI-focused | basic |
| Global **RPS cap** (`--rate`) | ✅ | — | per-worker (`-q`) | ✅ | different model |
| **Total request deadline** (`--request-timeout`) | ✅ | — | — | — | — |
| **Warmup**, **proxy**, **cookies**, multi-URL file | ✅ | — | partial | partial | — |
| **Follow redirects**, custom **success** HTTP codes | ✅ | — | partial | partial | — |
| **No keep-alive** mode (`--disable-keepalive`) | ✅ | default (enable with `-k`) | ✅ | ✅ (HTTP/1.1) | via Lua |
| **Body** from string / file / stdin | ✅ / ✅ / ✅ | file (`-p`) | ✅ / ✅ / — | ✅ / ✅ / — | via Lua |
| **HTTP/2** | — (HTTP/1.1) | — | ✅ (`-h2`) | ✅ (`--http2`) | — |
| **Multi-core** load generation | ✅ (`--workers`) | — | ✅ (`-cpus`) | ✅ | ✅ (`-t`) |
| **Scriptable** load (Lua, etc.) | — | — | — | — | ✅ |
| **Cross-platform** binary | ✅ (Linux, macOS, Windows) | Linux | ✅ | ✅ | Linux |

Coordinated-omission correction is also available in [wrk2](https://github.com/giltene/wrk2), the fork that introduced the technique; plain wrk, ab, hey and oha report service time only.
## Which tool should I use?
**Choose wrk** when you need Lua-driven scenarios — request generation, custom protocols, response validation in-process — and maximum tuning on Linux.
**Choose ab** when the classic Apache Bench one-liner is enough — plain-text summaries, GET-heavy checks, and httpd-family packages already on the machine.
**Choose hey or oha** when you need HTTP/2, or when you want oha's live TUI while poking at a service by hand.
**Choose cryload** when you want to **gate a pipeline on honest latency**: coordinated-omission-corrected percentiles, a threshold matrix that can be scoped per endpoint, an exit code taxonomy that distinguishes a slow service from an unreachable one, and JSON/CSV reports with per-URL, per-status and per-phase breakdowns — in one cross-platform binary that also saturates every core.
---
*Last updated: 2026-08-29*
