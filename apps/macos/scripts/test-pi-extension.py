#!/usr/bin/env python3
"""Check Dahlia's Pi extension against the bundled Pi and a loopback Responses API.

Usage: python3 apps/macos/scripts/test-pi-extension.py [--pi .build/pi-helper/pi/pi]
Uses an isolated agent directory and synthetic tokens; nothing leaves 127.0.0.1.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[3]
EXTENSION = ROOT / "apps/macos/Sources/Dahlia/PiExtension/dahlia.ts"
CHAT_ARGUMENTS = ["--no-session", "-e", "builtin:mcp", "--tools", "read,ls,mcp__dahlia__*"]
# A stand-in for dahlia-mcp with one read-only and one changing tool.
MCP_SERVER = """
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    method = msg.get("method")
    result = {}
    if method == "initialize":
        result = {"protocolVersion": msg["params"].get("protocolVersion"), "capabilities": {"tools": {}},
                  "serverInfo": {"name": "dahlia", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ("get_meeting", "update_meeting")]}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "MCP_OK"}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\\n")
    sys.stdout.flush()
"""


def gateway(script, requests):
    """Answers each request with the next scripted text or tool call."""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append({"auth": self.headers.get("Authorization"), "body": body})
            step = script[min(len(requests) - 1, len(script) - 1)]
            usage = {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                     "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}
            response = {"id": "r", "object": "response", "status": "completed", "model": body["model"], "output": [], "usage": usage}
            if "tool" in step:
                name, arguments = step["tool"], step.get("args", {})
                item = {"type": "function_call", "id": "fc", "call_id": "call", "name": name,
                        "arguments": json.dumps(arguments), "status": "completed"}
            else:
                item = {"type": "message", "id": "m", "role": "assistant", "status": "completed",
                        "content": [{"type": "output_text", "text": step["text"], "annotations": []}]}
            events = [{"type": "response.created", "response": dict(response, status="in_progress")},
                      {"type": "response.output_item.done", "output_index": 0, "item": item},
                      {"type": "response.completed", "response": response}]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write("".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode())

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run(pi, mode, script, arguments, environment, approval="accept", approval_mode="ask"):
    """Runs one prompt; returns the gateway requests, tool results, bridge calls, and whether ../outside.txt exists."""
    requests, tool_results, bridge = [], [], []
    server = gateway(script, requests)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary).resolve()
        (root / "agent").mkdir()
        (root / "workspace").mkdir()
        (root / "agent/auth.json").write_text('{"marker": "SECRET_MARKER"}')
        (root / "workspace/inside.txt").write_text("INSIDE_MARKER")
        (root / "workspace/link").symlink_to(root / "agent/auth.json")
        provider = {"baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": "openai-responses",
                    "apiKey": "dahlia", "authHeader": True,
                    "models": [{"id": "mock", "name": "Mock", "reasoning": True, "input": ["text"],
                                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                                "contextWindow": 100000, "maxTokens": 1000}]}
        (root / "agent/models.json").write_text(json.dumps({"providers": {"dahlia-databricks-openai": provider}}))
        env = dict(os.environ, PI_CODING_AGENT_DIR=str(root / "agent"), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1",
                   PI_TELEMETRY="0", DAHLIA_PI_MODE=mode, DAHLIA_PI_BRIDGED_PROVIDERS="dahlia-databricks-openai",
                   DAHLIA_PI_READABLE_ROOTS=json.dumps([str(root / "workspace")]), **environment)
        process = subprocess.Popen(
            [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills", "--no-context-files",
             "--no-prompt-templates", "--no-themes", "--no-approve", "--model", "dahlia-databricks-openai/mock", *arguments],
            cwd=root / "workspace", env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

        def send(record):
            process.stdin.write((json.dumps(record) + "\n").encode())
            process.stdin.flush()

        send({"id": "p", "type": "prompt", "message": "go"})
        for line in process.stdout:
            record = json.loads(line)
            if record.get("type") == "extension_ui_request" and record.get("title", "").startswith("dahlia:"):
                method = record["title"].removeprefix("dahlia:")
                bridge.append((method, json.loads(record["placeholder"])))
                answers = {"token": "synthetic-token", "approvalMode": approval_mode, "approval": approval}
                send({"type": "extension_ui_response", "id": record["id"], "value": json.dumps(answers[method])})
            elif record.get("type") == "tool_execution_end":
                tool_results.append("".join(part.get("text", "") for part in record["result"]["content"]))
            elif record.get("type") == "agent_settled":
                break
        process.stdin.close()
        process.wait(timeout=20)
        server.shutdown()
        outside_written = (root / "outside.txt").exists()
    return requests, tool_results, bridge, outside_written


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pi", default=str(ROOT / ".build/pi-helper/pi/pi"))
    pi = parser.parse_args().pi

    with tempfile.NamedTemporaryFile("w", suffix=".json") as schema:
        json.dump({"type": "object", "properties": {"a": {"type": "string"}}, "required": ["a"]}, schema)
        schema.flush()
        for strict in ("1", "0"):
            requests, _, bridge, _ = run(pi, "summary", [{"text": '{"a":"日本語"}'}], ["--no-session", "--no-tools"],
                                             {"DAHLIA_PI_OUTPUT_SCHEMA": schema.name, "DAHLIA_PI_STRICT_SCHEMA": strict})
            assert requests[0]["auth"] == "Bearer synthetic-token", requests[0]["auth"]
            assert bridge[0] == ("token", {"provider": "dahlia-databricks-openai"}), bridge
            format_ = requests[0]["body"].get("text", {}).get("format")
            assert (format_ is not None) == (strict == "1"), format_
            assert "tools" not in requests[0]["body"] or not requests[0]["body"]["tools"]

    with tempfile.NamedTemporaryFile("w", suffix=".py") as mcp:
        mcp.write(MCP_SERVER)
        mcp.flush()
        environment = {"DAHLIA_PI_MCP_COMMAND": json.dumps(["/usr/bin/python3", mcp.name])}

        def chat(*steps, **options):
            return run(pi, "chat", [*steps, {"text": "done"}], CHAT_ARGUMENTS, environment, **options)

        requests, results, _, _ = chat({"tool": "read", "args": {"path": "inside.txt"}})
        names = [tool.get("name") for tool in requests[0]["body"].get("tools", [])]
        assert {"read", "ls", "mcp__dahlia__get_meeting"} <= set(names) and "bash" not in names, names
        assert "INSIDE_MARKER" in results[0], results

        # Every spelling of a path outside the workspace stays unreadable, including a symlink out of it.
        for tool, path in [("read", "../agent/auth.json"), ("read", "@../agent/auth.json"), ("read", "~"),
                           ("read", "link"), ("ls", ".."), ("ls", "~")]:
            _, results, _, _ = chat({"tool": tool, "args": {"path": path}})
            assert "can read only" in results[0] and "SECRET_MARKER" not in results[0], (tool, path, results)

        # Tools outside the list never run, even when the model calls them.
        _, _, _, outside = chat({"tool": "bash", "args": {"command": "echo x > ../outside.txt"}})
        assert not outside

        _, results, bridge, _ = chat({"tool": "mcp__dahlia__get_meeting"})
        assert results == ["MCP_OK"] and not any(method == "approval" for method, _ in bridge), (results, bridge)
        _, results, bridge, _ = chat({"tool": "mcp__dahlia__update_meeting", "args": {"title": "x"}})
        approvals = [payload for method, payload in bridge if method == "approval"]
        assert [(p["kind"], p["tool"]) for p in approvals] == [("mcpToolCall", "update_meeting")], bridge
        assert results == ["MCP_OK"], results
        _, results, _, _ = chat({"tool": "mcp__dahlia__update_meeting"}, approval="decline")
        assert "declined" in results[0], results
        _, results, bridge, _ = chat({"tool": "mcp__dahlia__update_meeting"}, approval_mode="autoReview")
        assert results == ["MCP_OK"] and not any(method == "approval" for method, _ in bridge), (results, bridge)
    print("Pi extension tests passed (token bridge, strict schema, read-only chat, MCP approval)")


if __name__ == "__main__":
    main()
