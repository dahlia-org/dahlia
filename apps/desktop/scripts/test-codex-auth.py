#!/usr/bin/env python3
"""Check the pinned Codex bearer-command/401 contract against a loopback Gateway.

Usage: python3 apps/desktop/scripts/test-codex-auth.py --codex /path/to/codex
Uses only synthetic credentials and an isolated CODEX_HOME. OAuth and broker
behavior are covered by DatabricksOAuthServiceTests and DahliaTokenBrokerTests.
"""
import argparse
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


def check(codex, scenario):
    requests = []
    class Gateway(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"models":[]}')

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            requests.append((self.path, self.headers.get("Authorization"), body, int(counter.read_text())))
            if scenario == "refresh-fails":
                failure_marker.touch()
            if len(requests) == 1 or scenario != "recovers":
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":{"message":"expired","type":"authentication_error"}}')
                return
            item = {"type": "message", "id": "msg_test", "role": "assistant",
                    "content": [{"type": "output_text", "text": "OK"}]}
            events = [
                {"type": "response.created", "response": {"id": "resp_test"}},
                {"type": "response.output_item.done", "output_index": 0, "item": item},
                {"type": "response.completed", "response": {"id": "resp_test", "status": "completed",
                    "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}},
            ]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for event in events:
                self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())

    server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="dahlia-auth-contract-") as folder:
            root = Path(folder)
            counter = root / "counter"
            failure_marker = root / "unauthorized"
            helper = root / "token.py"
            helper.write_text('''import pathlib, sys
path = pathlib.Path(sys.argv[1])
count = int(path.read_text()) + 1 if path.exists() else 1
path.write_text(str(count))
if len(sys.argv) > 2 and pathlib.Path(sys.argv[2]).exists():
    raise SystemExit(1)
print("synthetic-token-" + str(count))
''')
            args = [str(helper), str(counter)] + ([str(failure_marker)] if scenario == "refresh-fails" else [])
            (root / "config.toml").write_text(f'''
model_provider = "databricks"
model = "gpt-5.6"
[analytics]
enabled = false
[features]
enable_request_compression = false
[model_providers.databricks]
name = "Databricks Test"
base_url = "http://127.0.0.1:{server.server_port}/ai-gateway/codex/v1"
wire_api = "responses"
stream_max_retries = 0
requires_openai_auth = false
[model_providers.databricks.auth]
command = {json.dumps(sys.executable)}
args = {json.dumps(args)}
timeout_ms = 20000
refresh_interval_ms = 1500000
''')
            environment = {key: value for key, value in os.environ.items()
                           if key in ("PATH", "TMPDIR", "LANG", "SYSTEMROOT")}
            environment["CODEX_HOME"] = str(root)
            result = subprocess.run([str(codex), "exec", "--skip-git-repo-check", "--ephemeral",
                "--ignore-rules", "--sandbox", "read-only", "--json", "Reply OK without using tools."],
                cwd=root, env=environment, capture_output=True, text=True, timeout=45)
            expected_requests = 1 if scenario == "refresh-fails" else 2
            assert len(requests) == expected_requests, (scenario, len(requests), result.stderr[-1500:])
            initial_count = requests[0][3]
            assert int(counter.read_text()) == initial_count + 1, (scenario, counter.read_text(), initial_count)
            assert requests[0][1] == f"Bearer synthetic-token-{initial_count}", scenario
            assert requests[0][0] == "/ai-gateway/codex/v1/responses", requests[0][0]
            if expected_requests == 2:
                assert requests[1][1] == f"Bearer synthetic-token-{initial_count + 1}", scenario
                first_body, retry_body = json.loads(requests[0][2]), json.loads(requests[1][2])
                assert first_body == retry_body, ("401 recovery changed request fields",
                    [key for key in first_body.keys() | retry_body.keys() if first_body.get(key) != retry_body.get(key)])
            assert (result.returncode == 0) == (scenario == "recovers"), (scenario, result.stderr[-1500:])
            print(f"PASS {scenario}: {expected_requests} request(s), one authentication recovery")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True)
    args = parser.parse_args()
    codex = args.codex.resolve()
    expected = "0.153.4"
    result = subprocess.run([str(codex), "--version"], capture_output=True, text=True, check=True)
    assert result.stdout.strip() == "codex-cli " + expected, result.stdout
    for scenario in ("recovers", "unauthorized", "refresh-fails"):
        check(codex, scenario)


if __name__ == "__main__":
    main()
