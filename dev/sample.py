import json, math, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
class Metrics(BaseHTTPRequestHandler):
    def do_GET(self):
        value = 50 + 20 * math.sin(time.time() / 30)
        body = f'# TYPE queries_demo_load gauge\nqueries_demo_load{{service="demo"}} {value}\n'.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
threading.Thread(target=lambda: HTTPServer(('0.0.0.0', 8000), Metrics).serve_forever(), daemon=True).start()
i = 0
while True:
    payload = {'streams': [{'stream': {'job': 'queries-demo', 'service': 'demo'}, 'values': [[str(time.time_ns()), f'demo request completed sequence={i} status=200']]}]}
    try:
        request = urllib.request.Request('http://loki:3100/loki/api/v1/push', json.dumps(payload).encode(), {'Content-Type': 'application/json'})
        urllib.request.urlopen(request, timeout=5).close()
    except Exception as error:
        print(type(error).__name__, flush=True)
    i += 1
    time.sleep(5)
