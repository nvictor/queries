# Write a JSON import file

Create a `.json` file to load saved queries and collection settings into Queries. Start with the example below, or edit a file from **Collection → Export Collection…**.

Importing replaces your entire collection, including its context, time range, and auto-refresh settings. Queries asks you to confirm and backs up the existing collection before replacing it. Export first if you want a backup you can choose yourself.

## Create and import a collection

1. Save the example below as `Queries.json`.
2. Replace `my-grafana` with your authenticated gcx context and the data source UIDs with your own.
3. Change the titles, expressions, units, and notes as needed. Give each query a unique UUID. Run `uuidgen` in Terminal to generate one.
4. Choose **Collection → Import Collection…**, select the file, and confirm **Replace**.

```json
{
  "schemaVersion": 1,
  "context": "my-grafana",
  "rangeSeconds": 3600,
  "refreshSeconds": 0,
  "queries": [
    {
      "id": "D74453B8-06B6-4AD8-870F-9A10B8FA9AA1",
      "title": "Request rate",
      "text": "sum(rate(http_requests_total[5m]))",
      "language": "PromQL",
      "kind": "Time series",
      "datasourceUID": "my-prometheus",
      "unit": "requests/s",
      "notes": "Requests per second across all services.\nCompare spikes with deployment times."
    },
    {
      "id": "854CE85C-F6CE-4C4A-A293-8201089B79BF",
      "title": "API errors",
      "text": "{service=\"api\"} |= \"error\"",
      "language": "LogQL",
      "kind": "Logs",
      "datasourceUID": "my-loki",
      "unit": "",
      "notes": "Error messages from the API service."
    },
    {
      "id": "EC4E3414-F746-41CF-B7E2-B204C125D7E1",
      "title": "API log rate",
      "text": "sum(rate({service=\"api\"}[1m]))",
      "language": "LogQL",
      "kind": "Time series",
      "datasourceUID": "my-loki",
      "unit": "entries/s",
      "notes": "Log volume, including successful requests."
    }
  ]
}
```

These expressions depend on metrics and labels in your data sources. A valid import does not guarantee that a query will run or return results.

## Collection fields

All collection fields are required. Field names and enum values are case-sensitive.

| Field | JSON type | Accepted values |
| --- | --- | --- |
| `schemaVersion` | Integer | Must be `1`. |
| `context` | String | Your authenticated gcx context. An empty string imports, but you must choose a context in Settings before running queries. |
| `rangeSeconds` | Number | A finite number greater than zero. For example, `900` for 15 minutes, `3600` for one hour, or `86400` for 24 hours. |
| `refreshSeconds` | Integer | `0` (off), `30`, `60`, or `300`. |
| `queries` | Array of query objects | Queries appear in array order. An empty array is valid and replaces your collection with no queries. |

## Query fields

Every query field is required except `notes`. Empty strings are allowed only where described below.

| Field | JSON type | Accepted values |
| --- | --- | --- |
| `id` | String | A valid UUID, unique within the collection. Keep it when editing a query. Generate a new UUID when copying one. |
| `title` | String | The card title. Must contain at least one non-whitespace character. |
| `text` | String | The query expression. Must contain at least one non-whitespace character. |
| `language` | String | Exactly `"PromQL"` or `"LogQL"`. |
| `kind` | String | Exactly `"Time series"` or `"Logs"`. PromQL requires `"Time series"`. LogQL supports either kind. |
| `datasourceUID` | String | A nonempty Grafana data source UID, not its display name. Use a Prometheus source for PromQL and a Loki source for LogQL. |
| `unit` | String | A display label, such as `"requests/s"`. Use `""` for no label. It does not convert values. |
| `notes` | String or null | Optional context shown by the card’s info button. Missing, `null`, and `""` all mean no notes. |

Use JSON escaping inside strings: `\"` for a quote, `\n` for a newline, and `\\` for a backslash. Write numbers as numbers, not quoted strings. Do not include comments or trailing commas.

The file contains saved query definitions and settings. It does not contain result data, credentials, or the gcx executable path. Unknown fields are ignored during decoding and are not retained when the collection is saved or exported.

## Fix import problems

- **Missing field or wrong type:** Include every required field with the type listed above. Defaults in the Swift model do not fill missing JSON fields, except `notes`.
- **Unsupported collection version:** Set `schemaVersion` to `1`.
- **Invalid settings or duplicate identifiers:** Check the time range, supported refresh intervals, and unique UUIDs.
- **Invalid query:** Check for blank titles or expressions, empty data source UIDs, and PromQL queries with `"kind": "Logs"`.
- **Import succeeds but running fails:** Check your gcx authentication, context, data source UID, and expression. Import validates the file structure and model rules without contacting Grafana.

A decoding or validation failure leaves the existing collection unchanged. A successful replacement stores a backup named `collection-backup-<UUID>.json` beside the app’s saved `collection.json` in its Application Support `Queries` directory.
