#!/usr/bin/env python3
"""Check Dahlia's Pi extension against an installed Pi, a loopback model gateway, and loopback MCPs.

Usage: python3 apps/macos/scripts/test-pi-extension.py [--pi /path/to/pi]  (default: pi on PATH)
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


def http_mcp(authorizations):
    """A streamable HTTP stand-in for a Unity AI Gateway MCP with one read-only and one changing tool."""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(405)
            self.end_headers()

        def do_POST(self):
            msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            authorizations.append(self.headers.get("Authorization"))
            if "id" not in msg:
                self.send_response(202)
                self.end_headers()
                return
            method = msg.get("method")
            result = {}
            if method == "initialize":
                result = {"protocolVersion": msg["params"].get("protocolVersion"), "capabilities": {"tools": {}},
                          "serverInfo": {"name": "gmail", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [
                    {"name": "search_messages", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}},
                    {"name": "send_message", "inputSchema": {"type": "object"}},
                ]}
            elif method == "tools/call":
                result = {"content": [{"type": "text", "text": "GATEWAY_OK"}]}
            body = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def gateway(script, requests):
    """Answers each request with the next scripted text or tool call."""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append({"auth": self.headers.get("Authorization"),
                             "tags": self.headers.get("Databricks-Ai-Gateway-Request-Tags"), "body": body})
            step = script[min(len(requests) - 1, len(script) - 1)]
            if "redirect" in step:
                self.send_response(307)
                self.send_header("Location", step["redirect"])
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            usage = {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                     "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}
            response = {"id": "r", "object": "response", "status": "completed", "model": body.get("model"), "output": [], "usage": usage}
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


def run(pi, mode, script, arguments, environment, approval="accept", approval_mode="ask", api="openai-responses", mcp_servers=None):
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
        if mcp_servers is not None:
            (root / "agent/mcp.json").write_text(json.dumps({"mcpServers": mcp_servers}))
        # Like Dahlia's models.json: no key; the extension resolves the bridged provider's credential.
        provider = {"baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": api, "authHeader": True,
                    "headers": {"Databricks-Ai-Gateway-Request-Tags": '{"source": "dahlia"}'},
                    "models": [{"id": "mock", "name": "Mock", "reasoning": True, "input": ["text"],
                                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                                "contextWindow": 100000, "maxTokens": 1000}]}
        (root / "agent/models.json").write_text(json.dumps({"providers": {"databricks": provider}}))
        env = dict(os.environ, PI_CODING_AGENT_DIR=str(root / "agent"), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1",
                   PI_TELEMETRY="0", DAHLIA_PI_MODE=mode, DAHLIA_PI_BRIDGED_PROVIDERS="databricks",
                   DAHLIA_PI_READABLE_ROOTS=json.dumps([str(root / "workspace")]), **environment)
        process = subprocess.Popen(
            [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills", "--no-context-files",
             "--no-prompt-templates", "--no-themes", "--no-approve", "--model", "databricks/mock", *arguments],
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
    parser.add_argument("--pi", default="pi")
    pi = parser.parse_args().pi

    with tempfile.NamedTemporaryFile("w", suffix=".json") as schema:
        json.dump({"type": "object", "properties": {"a": {"type": "string"}}, "required": ["a"]}, schema)
        schema.flush()
        for strict in ("1", "0"):
            requests, _, bridge, _ = run(pi, "summary", [{"text": '{"a":"日本語"}'}], ["--no-session", "--no-tools"],
                                             {"DAHLIA_PI_OUTPUT_SCHEMA": schema.name, "DAHLIA_PI_STRICT_SCHEMA": strict})
            assert requests[0]["auth"] == "Bearer synthetic-token", requests[0]["auth"]
            assert bridge[0] == ("token", {"provider": "databricks"}), bridge
            format_ = requests[0]["body"].get("text", {}).get("format")
            assert (format_ is not None) == (strict == "1"), format_
            assert "tools" not in requests[0]["body"] or not requests[0]["body"]["tools"]

    with tempfile.NamedTemporaryFile("w", suffix=".py") as mcp:
        mcp.write(MCP_SERVER)
        mcp.flush()
        environment = {"DAHLIA_PI_MCP_COMMAND": json.dumps(["/usr/bin/python3", mcp.name]),
                       "DAHLIA_PI_MCP_SERVERS": json.dumps(["dahlia"])}

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

    # Every model API Dahlia configures for a bridged provider gets the account's token.
    # The Databricks catalog's APIs, plus the Dahlia Server's (OpenAI Responses).
    catalog = json.loads((ROOT / "apps/macos/Sources/Dahlia/PiExtension/databricks-models.json").read_text())
    apis = {model["api"] for provider in catalog.values() for model in provider["models"]} | {"openai-responses"}
    for api in sorted(apis):
        requests, _, _, _ = run(pi, "summary", [{"text": "{}"}], ["--no-session", "--no-tools"], {}, api=api)
        assert requests and requests[0]["auth"] == "Bearer synthetic-token", (api, requests[:1])
        # models.json still layers its headers over the provider the extension registers.
        assert requests[0]["tags"] == '{"source": "dahlia"}', (api, requests[0]["tags"])

    # A redirect never carries the token to another origin.
    elsewhere = []
    other = gateway([{"text": "{}"}], elsewhere)
    run(pi, "summary", [{"redirect": f"http://127.0.0.1:{other.server_port}/v1/responses"}, {"text": "{}"}],
        ["--no-session", "--no-tools"], {})
    assert all(request["auth"] is None for request in elsewhere), elsewhere
    other.shutdown()

    # An mcp.json MCP that names the bridged provider in `auth.provider` gets its token per request and reaches the
    # first prompt; one without it never does. Only read-only gateway tools skip approval.
    authorizations, foreign = [], []
    server, foreign_server = http_mcp(authorizations), http_mcp(foreign)
    mcp_servers = {"gmail": {"url": f"http://127.0.0.1:{server.server_port}/mcp", "exposure": "direct",
                             "auth": {"provider": "databricks"}},
                   "foreign": {"url": f"http://127.0.0.1:{foreign_server.server_port}/mcp", "exposure": "direct"}}
    arguments = ["--no-session", "-e", "builtin:mcp", "--tools", "read,ls,mcp__gmail__*"]

    def gateway_chat(*steps, arguments=arguments, **options):
        return run(pi, "chat", [*steps, {"text": "done"}], arguments, {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"])},
                   mcp_servers=mcp_servers, **options)

    requests, results, bridge, _ = gateway_chat({"tool": "mcp__gmail__search_messages"})
    names = [tool.get("name") for tool in requests[0]["body"].get("tools", [])]
    assert {"mcp__gmail__search_messages", "mcp__gmail__send_message"} <= set(names), names
    assert "mcp__foreign__search_messages" not in names, names
    assert authorizations and set(authorizations) == {"Bearer synthetic-token"}, authorizations
    assert any(method == "token" and payload == {"provider": "databricks"} for method, payload in bridge), bridge
    assert foreign and set(foreign) == {None}, foreign
    assert results == ["GATEWAY_OK"] and not any(method == "approval" for method, _ in bridge), (results, bridge)
    _, results, bridge, _ = gateway_chat({"tool": "mcp__gmail__send_message"}, approval="decline")
    approvals = [payload for method, payload in bridge if method == "approval"]
    assert [(p["server"], p["tool"]) for p in approvals] == [("gmail", "send_message")], bridge
    assert "declined" in results[0], results
    # A server Dahlia did not register stays blocked even if its tools get past --tools.
    _, results, bridge, _ = gateway_chat({"tool": "mcp__foreign__search_messages"}, approval_mode="autoReview",
                                         arguments=["--no-session", "-e", "builtin:mcp", "--tools", "read,ls,mcp__gmail__*,mcp__foreign__*"])
    assert "not available" in results[0] and "GATEWAY_OK" not in results[0], results
    server.shutdown()
    foreign_server.shutdown()
    print("Pi extension tests passed (token bridge, strict schema, read-only chat, MCP approval, model APIs, gateway MCP)")


if __name__ == "__main__":
    main()
