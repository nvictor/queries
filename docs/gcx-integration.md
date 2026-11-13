# gcx integration record

Validated locally on November 12, 2026. All fixtures contain synthetic local data.

| Component | Tested version |
| --- | --- |
| gcx | 1.7.1, commit `94c0de01de861c5c0727b7d82b3edf1dc60a7d11` |
| Grafana | 12.3.0 |
| Prometheus | 3.3.0 |
| Loki | 3.5.0 |
| Sample exporter | Python 3.13.3 |
| Xcode / SDK | 27.2 / macOS 27.2 |

## Verified routes

Context: `queries-local`. Grafana: `http://localhost:3300`.

- Prometheus UID `queries-prometheus`, plugin `prometheus`.
- Loki UID `queries-loki`, plugin `loki`.
- Both data sources use Grafana proxy access. No separately configured backend endpoints were needed.
- `gcx datasources list --context queries-local -o json` returns a `datasources` array with `uid`, `name`, and `type`.

Exact query argument patterns, with absolute RFC3339 boundaries recorded in `Tests/QueriesCoreTests/Fixtures/window.json`:

```text
gcx datasources query queries-prometheus --expr queries_demo_load --context queries-local --from START --to END --step 10s -o json --no-color
gcx datasources query queries-loki --expr '{job="queries-demo"}' --context queries-local --from START --to END --limit 1000 -o json --no-color
gcx logs metrics --datasource queries-loki --expr 'sum(rate({job="queries-demo"}[1m]))' --context queries-local --from START --to END --step 10s -o json --no-color
```

The generic Loki route rejects metric results and explicitly directs callers to `logs metrics`. The app selects this route from the saved language and result kind, without inspecting query substrings.

## Payloads and normalization

- Metrics: `status: success`, `data.resultType: matrix`, and `data.result[].metric` plus `values` containing numeric Unix seconds and string values. Instant `vector` payloads are also decoded.
- Logs: `data.resultType: streams`. Each stream has labels and `values` objects containing a nanosecond `timestamp` string, `line`, and optional `structuredMetadata`.
- Log timestamp strings remain intact. Sorting uses integer nanoseconds; duplicate identities include a content digest and occurrence number.
- Non-finite metric values remain missing values. Drawing connects valid points with monotone interpolation. Hover reports recorded samples and bridged intervals, without manufacturing samples or zeros.
- The step targets 600 samples per series, with a ten-second minimum. The spike observed the generic Prometheus route using ten seconds even when five seconds was requested. No arbitrary upper clamp is applied.
- The app explicitly selects JSON, disables agent mode and color, and does not request field filtering or spill files. The tested commands emitted JSON to stdout and a harmless hint to stderr. Neither terminal tables nor agent envelopes are decoded.
- Warnings are presented as counts. Raw diagnostics and responses are not logged or included in exported collections.

## Evidence and limits

- All three captured query kinds were nonempty. `dev/capture-fixtures.py` compared every timestamp and value or log line with Grafana's `/api/ds/query` endpoint used by Explore, using identical absolute boundaries and ten-second metric intervals. All comparisons passed.
- Comparison was against Explore's query API, rather than visual inspection of the Grafana Explore web UI.
- Queries was launched through Launch Services, connected to this context, and displayed live native charts and logs. A restart retained the saved collection and ordering.
- Thirteen automated tests passed: observed payloads, missing/non-finite/single samples, malformed responses, duplicate logs, nanosecond ordering, persistence and recovery, literal arguments, nonzero exits, timeouts, cancellation, output bounds, concurrent pipe draining, concurrency, late responses, stale data, and inactive refresh suspension.
- Debug build and unsigned Release archive succeeded. The workflow YAML, embedded shell syntax, and export plist were checked locally. Developer ID export, notarization, and GitHub runner execution remain untested. The workflow was not triggered.
- The registry did not contain `grafana/grafana:13.0.0`; the spike used the available pinned 12.3.0 image successfully. This does not establish compatibility with other gcx/Grafana versions.
- GMP plugin and authentication compatibility remain a separate follow-up. Local Prometheus validation is not GMP validation.
