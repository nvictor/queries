#!/usr/bin/env python3
"""Capture only local synthetic results. Never point this at production."""
import datetime, json, pathlib, subprocess, urllib.request, base64
root = pathlib.Path(__file__).resolve().parents[1]
fixtures = root / 'Tests/QueriesCoreTests/Fixtures'
now = datetime.datetime.now(datetime.timezone.utc)
end = datetime.datetime.fromtimestamp(int(now.timestamp()) // 10 * 10, datetime.timezone.utc)
start = end - datetime.timedelta(minutes=15)
window = {'from': start.isoformat().replace('+00:00', 'Z'), 'to': end.isoformat().replace('+00:00', 'Z')}
fixtures.mkdir(parents=True, exist_ok=True)
(fixtures / 'window.json').write_text(json.dumps(window, indent=2) + '\n')
queries = [
    ('prometheus', 'queries-prometheus', 'queries_demo_load', ['datasources', 'query', 'queries-prometheus']),
    ('loki-logs', 'queries-loki', '{job="queries-demo"}', ['datasources', 'query', 'queries-loki']),
    ('loki-metrics', 'queries-loki', 'sum(rate({job="queries-demo"}[1m]))', ['logs', 'metrics', '--datasource', 'queries-loki']),
]
for name, uid, expr, command in queries:
    args = ['gcx', *command, '--expr', expr, '--context', 'queries-local', '--from', window['from'], '--to', window['to'], '-o', 'json', '--no-color']
    args += ['--limit', '1000'] if name == 'loki-logs' else ['--step', '10s']
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    payload = json.loads(result.stdout)
    assert payload['status'] == 'success' and payload['data']['result'], f'{name}: wait for sample data, then retry'
    (fixtures / (name + '.json')).write_text(json.dumps(payload, indent=2) + '\n')
    print(name + ': saved nonempty fixture')
    # Compare against the same Grafana query API used by Explore, with identical boundaries.
    query = {'refId': 'A', 'datasource': {'uid': uid, 'type': 'prometheus' if name == 'prometheus' else 'loki'},
             'expr': expr, 'intervalMs': 10000, 'maxDataPoints': 90, 'range': True,
             'instant': False, 'queryType': 'range', 'editorMode': 'code', 'maxLines': 1000}
    body = {'from': str(int(start.timestamp()*1000)), 'to': str(int(end.timestamp()*1000)), 'queries': [query]}
    request = urllib.request.Request('http://localhost:3300/api/ds/query', json.dumps(body).encode(),
        {'Content-Type': 'application/json', 'Authorization': 'Basic ' + base64.b64encode(b'admin:queries-local-only').decode()})
    with urllib.request.urlopen(request, timeout=30) as response:
        grafana = json.load(response)
    frames = grafana['results']['A']['frames']
    assert frames and not grafana['results']['A'].get('error'), name
    # Match sample timestamps and values across the CLI proxy and Explore query API.
    observed = []
    for frame in frames:
        fields, values = frame['schema']['fields'], frame['data']['values']
        time_index = next((i for i,f in enumerate(fields) if f['type'] == 'time'), None)
        if time_index is None: continue
        if name == 'loki-logs':
            line_index = next(i for i,f in enumerate(fields) if f['name'] == 'Line')
            observed.extend((int(float(t)), str(v)) for t,v in zip(values[time_index], values[line_index]))
        else:
            for i,field in enumerate(fields):
                if field['type'] == 'number': observed.extend((int(t), float(v)) for t,v in zip(values[time_index], values[i]) if v is not None)
    expected = []
    for row in payload['data']['result']:
        if name == 'loki-logs':
            expected.extend((int(v['timestamp']) // 1000000, v['line']) for v in row['values'])
        else: expected.extend((int(float(t)*1000), float(v)) for t,v in row['values'])
    print('sample counts:', len(expected), len(observed), 'first:', expected[:2], observed[:2])
    assert sorted(expected) == sorted(observed), f'{name}: Explore API sample mismatch'
    print(name + ': exact timestamps and values match Grafana Explore query API')
