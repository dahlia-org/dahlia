#!/usr/bin/env python3
"""Check Dahlia's Pi extension against an installed Pi, a loopback model gateway, and loopback MCPs.

Usage: DAHLIA_PI_AUTO_REVIEW=/path/to/pi-auto-review/index.ts python3 apps/macos/scripts/test-pi-extension.py [--pi /path/to/pi]
(default: pi on PATH; use a checkout of the commit pinned in AgentAutoReviewSettings.packageSource)
Uses an isolated agent directory and synthetic tokens; nothing leaves 127.0.0.1.
Optional: --web-access-package /path/to/npm/node_modules/pi-web-access also checks the real MCP worker.
"""
import argparse
import base64
import hashlib
import socket
import shutil
import shlex
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import threading
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = Path(__file__).resolve().parents[3]
EXTENSION = ROOT / "apps/macos/Sources/Dahlia/PiExtension/dahlia.ts"
# dahlia.ts registers the Unity AI Gateway sign-ins in every process, so chat adds only Pi's MCP extension, as Dahlia does.
CHAT_EXTENSIONS = ["-e", "builtin:mcp"]
CHAT_ARGUMENTS = ["--no-session", *CHAT_EXTENSIONS, "--tools", "read,ls,write,edit,bash,mcp__dahlia__*"]
SANDBOX = EXTENSION.with_name("pi.sb")
# Standalone MCP fixture: verifies transport, the worker environment, and the direct URL/auth gate.
WEB_ACCESS_STUB = """import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
for await (const line of createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!("id" in message)) continue;
  let result = {};
  if (message.method === 'initialize') result = {
    protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'web', version: '1' }
  };
  if (message.method === 'tools/list') result = { tools: [{
    name: 'fetch_content', description: 'Fetch a web page.', inputSchema: {
      type: 'object', properties: { url: { type: 'string' }, urls: { type: 'array', items: { type: 'string' } }, auth: {} }
    }
  }] };
  if (message.method === 'tools/call') {
    let protectedRead = false;
    try { readFileSync(process.env.PI_CODING_AGENT_DIR + '/auth.json'); protectedRead = true; } catch {}
    const isolated = !protectedRead && !process.env.GH_TOKEN && !process.env.PI_ALLOW_BROWSER_COOKIES && !process.env.FEYNMAN_ALLOW_BROWSER_COOKIES
      && process.env.HOME.endsWith('/web-access-runtime') && process.env.TMPDIR === process.env.HOME;
    result = { content: [{ type: 'text', text: isolated ? 'FETCHED' : 'ENVIRONMENT_LEAK' }] };
  }
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }) + String.fromCharCode(10));
}
"""


def sandbox(root):
    """The command prefix that runs chat's commands and file operations under Dahlia's Seatbelt profile, as `PiSandbox` does."""
    parameters = {"WORK": root / "workspace", "TMP": root / "tmp", "PI_TMP": root / "pi-tmp", "AGENT": root / "agent",
                  "APP_SUPPORT": root / "support", "RELEASED_APP_SUPPORT": root / "released", "RELEASED_AGENT": root / "released-agent", "PI": root / "pi",
                  "RESOURCES": EXTENSION.parent, "BOTS": root / "bots", "RELEASED_BOTS": root / "released-bots",
                  "SKILLS": root / "skills", "FILE_STORE": root / "FileStore", "DATABASE": root / "dahlia.sqlite"}
    defines = [arg for key, value in parameters.items() for arg in ("-D", f"{key}={os.path.realpath(value)}")]
    return ["/usr/bin/sandbox-exec", "-f", str(SANDBOX), *defines]
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
                # Gmail lists messages as JSON text; a thread listing has no threadId and is not a list of items.
                items = msg["params"].get("arguments", {}).get("probe_items")
                args = msg["params"].get("arguments", {})
                next_cursor = args.get("probe_next_cursor", "")
                if args.get("probe_case") == "pagination":
                    messages = [{"id": "m1", "threadId": "t1"}, {"id": "m2", "threadId": "t2"}]
                    cursor = args.get("cursor", "")
                    if args.get("query") == "other":
                        items, next_cursor = [], ""
                    elif args.get("max_results") == 1:
                        items, next_cursor = {"": (messages[:1], "p2"), "p2": (messages[1:], "p3"), "p3": ([], "")}[cursor]
                    else:
                        items, next_cursor = messages, ""
                text = json.dumps({"items": items, "nextCursor": next_cursor,
                                   "has_more": bool(next_cursor)}) if items is not None else "GATEWAY_OK"
                result = {"content": [{"type": "text", "text": text}]}
                if msg["params"].get("arguments", {}).get("probe_error"):
                    result = {"isError": True, "content": [{"type": "text", "text": "Source page failed"}]}
            body = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def oidc(grants, client_id="databricks-cli", redirect=None, scopes=frozenset({"ai-gateway", "unity-catalog", "offline_access"}),
         resources=None, credential_requests=None, metadata_response=None):
    """A workspace's OIDC endpoints for the MCP sign-in: authorize answers at once, and token checks the client and PKCE.
    `redirect` is the client's registered redirect URL; without one, the Databricks CLI's ports are accepted."""
    verifiers = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = dict(urllib.parse.parse_qsl(url.query))
            if url.path == "/api/2.1/unity-catalog/mcp-services" and self.headers.get("Authorization") == "Bearer denied":
                body = json.dumps({"error_code": "PERMISSION_DENIED", "message": "missing scope unity-catalog"}).encode()
                self.send_response(403)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if url.path.startswith("/api/2.1/unity-catalog/mcp-services/") and url.path.endswith("/user-credentials"):
                assert self.headers.get("Authorization") in {f"Bearer mcp-access-{len(grants)}", "Bearer synthetic-token"}
                service = url.path.split("/")[-2]
                if credential_requests is not None:
                    credential_requests.append(service)
                status, data = {
                    "main.default.notion": (200, {"provisioning_info": {"state": "ACTIVE"}}),
                    "system.ai.github": (200, {"provisioning_info": {"state": "ACTIVE"}, "options": {"access_token_expiration": "2030-01-01T00:00:00Z"}}),
                    "system.ai.gmail": (200, {"provisioning_info": {"state": "FAILED"}}),
                    "system.ai.slack": (404, {"error_code": "NOT_FOUND"}),
                    "system.ai.atlassian": (403, {"error_code": "PERMISSION_DENIED"}),
                    "system.ai.unsupported": (404, {"error_code": "ENDPOINT_NOT_FOUND"}),
                }[service]
                body = json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if url.path == "/api/2.1/unity-catalog/mcp-services/main.default.notion":
                assert self.headers.get("Authorization") in {f"Bearer mcp-access-{len(grants)}", "Bearer synthetic-token"}
                body = json.dumps(metadata_response["body"]).encode()
                self.send_response(metadata_response["status"])
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if url.path == "/api/2.1/unity-catalog/model-services":
                # One page of the gateway's model services, which Dahlia turns into models.json through its templates.
                assert self.headers.get("Authorization") in {f"Bearer mcp-access-{len(grants)}", "Bearer synthetic-token"}, \
                    self.headers.get("Authorization")
                assert query["parent"] == "schemas/system.ai", query
                body = json.dumps({"model_services": [{
                    "name": "model-services/system.ai.claude-haiku-5-5", "supported_api_types": ["anthropic/v1/messages"],
                    "capabilities": {"function_calling": True, "image_input": True}, "config": {"routing": {}}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if url.path == "/api/2.1/unity-catalog/mcp-services":
                # Two pages; the sign-in's latest token must reach the listing.
                # The workspace's own sign-in, or the account's bridged one.
                assert self.headers.get("Authorization") in {f"Bearer mcp-access-{len(grants)}", "Bearer synthetic-token"}, \
                    self.headers.get("Authorization")
                assert query["parent"] == "schemas/system.ai" and query["view"] == "BASIC", query
                services = ([{"name": "mcp-services/system.ai.atlassian"}, {"name": "mcp-services/system.ai.unsupported"}, {"name": "mcp-services/system.ai.slack"}, {"name": "mcp-services/system.ai.github", "comment": "Search repositories"}], "next") \
                    if "page_token" not in query else \
                    ([{"name": "mcp-services/system.ai.gmail", "config": {"connection": {"status": "ACTIVE"}}},
                      {"name": "mcp-services/system.ai.broken", "config": {"connection": {"status": "FAILED"}}},
                      {"name": "mcp-services/main.default.other"}], None)
                body = json.dumps({"mcp_services": services[0], **({"next_page_token": services[1]} if services[1] else {})}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            assert url.path == "/oidc/v1/authorize", url.path
            assert query["client_id"] == client_id, query
            assert set(query["scope"].split()) == scopes and query["code_challenge_method"] == "S256", query
            allowed = {redirect} if redirect else {f"http://localhost:{port}" for port in range(8020, 8041)}
            assert query["redirect_uri"] in allowed, query
            verifiers["code"] = query["code_challenge"]
            if resources is not None:
                resources.append(query.get("resource"))
            self.send_response(302)
            self.send_header("Location", query["redirect_uri"] + "?" + urllib.parse.urlencode({"code": "code", "state": query["state"]}))
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            form = dict(urllib.parse.parse_qsl(self.rfile.read(int(self.headers["Content-Length"])).decode()))
            assert self.path == "/oidc/v1/token" and form["client_id"] == client_id, (self.path, form)
            grants.append(form["grant_type"])
            if form["grant_type"] == "authorization_code":
                challenge = base64.urlsafe_b64encode(hashlib.sha256(form["code_verifier"].encode()).digest()).rstrip(b"=").decode()
                assert form["code"] == "code" and challenge == verifiers["code"], form
            else:
                assert form["refresh_token"] == "refresh-1", form
            body = json.dumps({"access_token": f"mcp-access-{len(grants)}", "token_type": "Bearer", "expires_in": 3600,
                               **({"refresh_token": "refresh-1"} if form["grant_type"] == "authorization_code" else {})}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def control(pi, command, auth=None, browser=False, environment=None, bridge_token="synthetic-token"):
    """Runs one command in a control process that loads only dahlia.ts, as Dahlia's sign-in and listing do, opening
    each auth URL when `browser`. Returns the `databricks:` notifications and auth.json afterward."""
    with tempfile.TemporaryDirectory() as temporary:
        agent = Path(temporary).resolve()
        if auth is not None:
            (agent / "auth.json").write_text(json.dumps(auth))
        env = dict(os.environ, PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1", PI_TELEMETRY="0",
                   DAHLIA_PI_MODE="control", **(environment or {}))
        process = subprocess.Popen(
            [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills", "--no-context-files",
             "--no-prompt-templates", "--no-themes", "--no-approve", "--no-session", "--no-tools"],
            cwd=agent, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        process.stdin.write((json.dumps({"id": "p", "type": "prompt", "message": command}) + "\n").encode())
        process.stdin.flush()
        messages = []
        for line in process.stdout:
            record = json.loads(line)
            # Dahlia answers the bridged provider's token request, as it does for the account's sign-in.
            if record.get("type") == "extension_ui_request" and record.get("title") == "dahlia:token":
                process.stdin.write((json.dumps({"type": "extension_ui_response", "id": record["id"],
                                                 "value": json.dumps(bridge_token)}) + "\n").encode())
                process.stdin.flush()
                continue
            message = record.get("message", "")
            if not message.startswith("databricks:"):
                continue
            messages.append(message)
            prefix, _, url = message.partition(" ")
            if prefix.endswith("auth_url"):
                if browser:
                    # The browser: the authorize endpoint redirects to the extension's loopback callback.
                    with urllib.request.urlopen(url, timeout=10) as response:
                        assert response.headers.get_content_type() == "text/html", response.headers
                        assert response.headers["Cache-Control"] == "no-store", response.headers
                        html = response.read().decode("utf-8")
                        assert 'data-state="success"' in html and "{{" not in html, html[:200]
            else:
                break
        process.stdin.close()
        process.wait(timeout=20)
        return messages, json.loads((agent / "auth.json").read_text())


def list_models(pi, auth, providers):
    """`pi --list-models` with Dahlia's extension, auth.json, and these models.json providers, as `provider model` lines."""
    with tempfile.TemporaryDirectory() as temporary:
        agent = Path(temporary).resolve()
        (agent / "auth.json").write_text(json.dumps(auth))
        (agent / "models.json").write_text(json.dumps({"providers": providers}))
        env = dict(os.environ, PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1", PI_TELEMETRY="0",
                   DAHLIA_PI_MODE="control")
        output = subprocess.run([pi, "--no-extensions", "-e", str(EXTENSION), "--list-models"], cwd=agent, env=env,
                                capture_output=True, text=True, timeout=60).stdout
        return [" ".join(line.split()[:2]) for line in output.splitlines()[1:]]


def mcp_login(pi, arguments):
    """Signs in like Dahlia does: `/databricks-login`, which dahlia.ts imports from the provider module. Returns auth.json."""
    messages, auth = control(pi, f"/databricks-login {arguments}", browser=True)
    assert messages[-1] == "databricks:login_succeeded", messages
    return auth


def gateway(script, requests, triage=False):
    """Answers each request with the next scripted text or tool call."""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append({"auth": self.headers.get("Authorization"),
                             "tags": self.headers.get("Databricks-Ai-Gateway-Request-Tags"), "body": body})
            if triage and self.path == "/systemone":
                # The first action needs review; later classifier answers would approve a retry.
                first = sum("questions" in request["body"] for request in requests) <= 2
                answers = ({"kind": {"probabilities": {"destroy" if first else "connected": 1}},
                            "has_secret": {"noul": 0.01}} if "kind" in body["questions"] else {"loosens": {"noul": 0.01}})
                payload = json.dumps({"answers": answers}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            index = sum("questions" not in request["body"] for request in requests) - 1
            step = script[min(index, len(script) - 1)]
            if "error" in step:
                body = json.dumps({"error": {"message": step["error"]}}).encode()
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if "redirect" in step:
                self.send_response(307)
                self.send_header("Location", step["redirect"])
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            usage = {"input_tokens": step.get("input_tokens", 1), "output_tokens": 1, "total_tokens": step.get("input_tokens", 1) + 1,
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


def run(pi, mode, script, arguments, environment, approval="accept", approval_mode="ask", api="openai-responses", mcp_servers=None,
        compat=None, auth=None, triage=False, prompts=1, bridge_answers=None, steer_message=None, web_access=None):
    """Runs prompts; returns gateway requests, tool results, bridge calls, and whether ../outside.txt exists."""
    requests, tool_results, bridge = [], [], []
    server = gateway(script, requests, triage=triage)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary).resolve()
        (root / "agent").mkdir()
        (root / "workspace").mkdir()
        (root / "agent/auth.json").write_text(json.dumps(auth or {"marker": "SECRET_MARKER"}))
        with sqlite3.connect(root / "dahlia.sqlite") as database:
            database.execute("CREATE TABLE debug (value TEXT)")
            database.execute("INSERT INTO debug VALUES ('SQLITE_MARKER')")
        (root / "workspace/inside.txt").write_text("INSIDE_MARKER")
        for protected in ("SOUL.md", "AGENTS.md", "bot.json"):
            (root / "workspace" / protected).write_text("PROTECTED_MARKER")
        (root / "workspace/pixel.png").write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        # Project-local Pi configuration that chat could have written must never start anything.
        (root / "workspace/.pi").mkdir()
        (root / "workspace/.pi/mcp.json").write_text(json.dumps(
            {"mcpServers": {"planted": {"command": "/usr/bin/touch", "args": [str(root / "outside.txt")]}}}))
        for folder in ("tmp", "pi-tmp", "skills"):
            (root / folder).mkdir()
        (root / "skills/SKILL.md").write_text("SKILL_MARKER")
        (root / "workspace/link").symlink_to(root / "agent/auth.json")
        (root / "workspace/shared-link").symlink_to(root / "skills/SKILL.md")
        (root / "workspace/protected-alias").symlink_to(root / "workspace/SOUL.md")
        (root / "tmp/shared.txt").write_text("OTHER_CHAT_MARKER")
        if mcp_servers is not None:
            (root / "agent/mcp.json").write_text(json.dumps({"mcpServers": mcp_servers}))
        # Like Dahlia's models.json: no key; the extension resolves the bridged provider's credential.
        provider = {"baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": api, "authHeader": True,
                    "headers": {"Databricks-Ai-Gateway-Request-Tags": '{"source": "dahlia"}'},
                    "models": [{"id": "mock", "name": "Mock", "reasoning": True, "input": ["text"],
                                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                                "contextWindow": 100000, "maxTokens": 1000, **({"compat": compat} if compat else {})}]}
        (root / "agent/models.json").write_text(json.dumps({"providers": {"databricks": provider}}))
        env = dict(os.environ, PI_CODING_AGENT_DIR=str(root / "agent"), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1",
                   PI_TELEMETRY="0", DAHLIA_PI_MODE=mode, DAHLIA_PI_BRIDGED_PROVIDERS="databricks",
                   DAHLIA_PI_SANDBOX=json.dumps(sandbox(root)), DAHLIA_PI_SANDBOX_HIDDEN_ENV=json.dumps(["USER_SECRET"]),
                   DAHLIA_PI_SANDBOX_TMPDIR=str(root / "tmp"), TMPDIR=str(root / "pi-tmp"),
                   USER_SECRET="ENV_SECRET_MARKER", **environment)
        if web_access:
            package = Path(web_access)
            if package.is_dir():
                assert json.loads((package / "package.json").read_text())["version"] == "0.47.0"
                shutil.copytree(package.parent, root / "agent/npm/node_modules", symlinks=True)
                entry = root / "agent/npm/node_modules/pi-web-access/dist/mcp-cli.js"
            else:
                entry = root / "agent/npm/node_modules/pi-web-access/dist/mcp-cli.mjs"
                entry.parent.mkdir(parents=True)
                shutil.copyfile(package, entry)
            scratch = root / "agent/web-access-runtime"
            scratch.mkdir()
            (root / "agent/web-search.json").write_text(json.dumps({"webSearch": {"enabled": False}, "allowBrowserCookies": True, "ssrf": {"allowRanges": ["127.0.0.0/8"]}}))
            node = Path(shutil.which("node")).resolve()
            # A version-manager shim is not the interpreter the worker sandbox should execute or grant.
            shim = root / "node-shim"
            shim.write_text("#!/bin/sh\nexec " + shlex.quote(str(node)) + ' "$@"\n')
            shim.chmod(0o700)
            command = ["/usr/bin/sandbox-exec", "-f", str(EXTENSION.with_name("web-access.sb")),
                       "-D", f"AGENT={root / 'agent'}", "-D", f"TMP={scratch}", "-D", f"NODE={shim}", "-D", f"NODE_RUNTIME={shim.parent}"]
            env.update(DAHLIA_PI_WEB_ACCESS=str(entry), DAHLIA_PI_WEB_NODE=str(shim), DAHLIA_PI_WEB_SANDBOX=json.dumps(command),
                       GH_TOKEN="SYNTHETIC_HOST_TOKEN", PI_ALLOW_BROWSER_COOKIES="1", FEYNMAN_ALLOW_BROWSER_COOKIES="1")
        process = subprocess.Popen(
            [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills", "--no-context-files",
             "--no-prompt-templates", "--no-themes", "--no-approve", "--model", "databricks/mock", *arguments],
            cwd=root / "workspace", env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

        def send(record):
            process.stdin.write((json.dumps(record) + "\n").encode())
            process.stdin.flush()

        send({"id": "p", "type": "prompt", "message": "go"})
        steered = False
        for line in process.stdout:
            record = json.loads(line)
            if steer_message and not steered and record.get("type") == "tool_execution_start":
                send({"id": "steer", "type": "steer", "message": steer_message})
                steered = True
            if record.get("type") == "extension_ui_request" and record.get("title", "").startswith("dahlia:"):
                method = record["title"].removeprefix("dahlia:")
                bridge.append((method, json.loads(record["placeholder"])))
                classifier = {"model": "system.ai.openjev-qwen35-4b", "provider": "databricks",
                              "endpoint": f"http://127.0.0.1:{server.server_port}/systemone"} if triage else None
                answers = {"token": "synthetic-token", "approvalMode": approval_mode, "reviewModel": "", "reviewTriage": classifier, "approvalCheck": True, "approval": approval, "createBackup": {"path": "/tmp/Dahlia-Backup-test.tar.gz"}}
                answers.update(bridge_answers or {})
                send({"type": "extension_ui_response", "id": record["id"], "value": json.dumps(answers[method])})
            elif record.get("type") == "tool_execution_end":
                tool_results.append("".join(part.get("text", "") for part in record["result"]["content"]))
            elif record.get("type") == "agent_settled":
                prompts -= 1
                if prompts == 0:
                    break
                send({"id": f"p{prompts}", "type": "prompt", "message": "go again"})
        process.stdin.close()
        process.wait(timeout=20)
        server.shutdown()
        outside_written = (root / "outside.txt").exists() or "CHANGED" in (root / "agent/auth.json").read_text()
    return requests, tool_results, bridge, outside_written


def web_access_regression(pi, package=None):
    def chat(*steps, profile="interactive", tool_names="mcp__dahlia_web_access__*", web_access=None):
        return run(pi, "chat", [*steps, {"text": "done"}], [*CHAT_ARGUMENTS[:-2], "--tools", tool_names],
                   {"DAHLIA_PI_PROFILE": profile}, web_access=web_access)

    web_access_package = package
    # The standalone web MCP runs inside its own Seatbelt profile, with an empty host credential environment.
    with tempfile.NamedTemporaryFile("w", suffix=".mjs") as web:
        web.write(WEB_ACCESS_STUB)
        web.flush()
        fetch = lambda **args: {"tool": "mcp__dahlia_web_access__fetch_content", "args": args}
        _, results, _, _ = chat(fetch(url="https://example.com"), fetch(url="../agent/auth.json"),
                                fetch(urls=["https://example.com", "file:///etc/hosts"]), fetch(url="https://example.com", auth=True),
                                tool_names="mcp__dahlia_web_access__*", web_access=web.name)
        assert results[0] == "FETCHED" and all("only fetches" in result for result in results[1:]), results
        for profile in ("scheduled", "review"):
            _, results, _, _ = chat(fetch(url="https://example.com"), profile=profile,
                                    tool_names="mcp__dahlia_web_access__*", web_access=web.name)
            assert "FETCHED" not in results[0], results
    if web_access_package:
        class PublicPage(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                body = b"<html><head><title>Offline web test</title></head><body>LOOPBACK_WEB_MARKER</body></html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        page = ThreadingHTTPServer(("127.0.0.1", 0), PublicPage)
        threading.Thread(target=page.serve_forever, daemon=True).start()
        try:
            _, results, _, _ = chat(
                {"tool": "mcp__dahlia_web_access__fetch_content",
                 "args": {"url": f"http://127.0.0.1:{page.server_port}/", "mode": "raw"}},
                tool_names="mcp__dahlia_web_access__*", web_access=web_access_package)
            assert "LOOPBACK_WEB_MARKER" in results[0], results
            print("Real pi-web-access 0.47.0 MCP worker fetched a loopback page under Seatbelt")
        finally:
            page.shutdown()



def curator_store_snapshots(pi):
    """Real Pi forwards decision snapshots through Dahlia's adapter and does not count skipped transitions."""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary).resolve()
        agent = root / "agent"
        records = {}
        for name, days in [("idle", 20), ("old", 400)]:
            directory = agent / "skills" / name
            directory.mkdir(parents=True)
            (directory / "SKILL.md").write_text(f"---\nname: {name}\ndescription: Test skill\n---\nSteps")
            stamp = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
            records[name] = {"created_by": "agent", "created_at": stamp, "last_used_at": stamp,
                             "use_count": 1, "state": "active", "pinned": False}
        env = dict(os.environ, PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE="1", PI_SKIP_VERSION_CHECK="1", PI_TELEMETRY="0",
                   DAHLIA_PI_MODE="chat", DAHLIA_PI_PROFILE="review", DAHLIA_PI_CURATOR="1", DAHLIA_PI_BRIDGED_PROVIDERS="",
                   DAHLIA_PI_CURATOR_SETTINGS=json.dumps({"staleAfterDays": 14, "archiveAfterDays": 90}))
        process = subprocess.Popen(
            [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills", "--no-context-files",
             "--no-prompt-templates", "--no-themes", "--no-approve", "--no-session", "--no-tools"],
            cwd=root, env=env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def send(record):
            process.stdin.write(json.dumps(record) + "\n")
            process.stdin.flush()

        mutations = []
        report = None
        try:
            send({"id": "sweep", "type": "prompt", "message": "/hermes-curator"})
            for line in process.stdout:
                record = json.loads(line)
                if record.get("type") == "extension_ui_request" and record.get("title", "").startswith("dahlia:"):
                    method = record["title"].removeprefix("dahlia:")
                    payload = json.loads(record["placeholder"])
                    if method == "skillStore":
                        if payload["action"] == "all":
                            answer = records
                        else:
                            assert payload["expected"] == records[payload["name"]], payload
                            mutations.append((payload["action"], payload["name"]))
                            answer = False
                    else:
                        assert method == "curatorReport", (method, payload)
                        report, answer = payload, None
                    send({"type": "extension_ui_response", "id": record["id"], "value": json.dumps(answer)})
                elif record.get("id") == "sweep":
                    assert record.get("success"), record
                    break
            assert mutations == [("set", "idle"), ("archive", "old")], mutations
            assert report["counts"]["markedStale"] == 0 and report["counts"]["archived"] == 0, report
        finally:
            process.stdin.close()
            process.wait(timeout=20)
            assert process.returncode == 0, process.stderr.read()


def package_resources(pi):
    """Real Pi resolves manifests and filters; account skills and installed package skills/prompts reach chat and the skills tab."""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary).resolve()
        agent, home = root / "agent", root / "home"
        package = agent / "git/example.com/tools"
        for directory in (agent / "skills/learned", package / "skills/packaged", package / "prompts", home / ".agents/skills/unrelated"):
            directory.mkdir(parents=True)
        (agent / "skills/learned/SKILL.md").write_text("---\nname: learned\ndescription: Account skill\n---\nLearned instructions")
        (package / "skills/packaged/SKILL.md").write_text("---\nname: packaged\ndescription: Package skill\n---\nPackage instructions")
        (package / "prompts/package-prompt.md").write_text("Package prompt")
        (home / ".agents/skills/unrelated/SKILL.md").write_text("---\nname: unrelated\ndescription: Unrelated skill\n---\nPrivate instructions")
        (agent / "skills/linked").symlink_to(home / ".agents/skills/unrelated", target_is_directory=True)
        (agent / "skills/linked.md").symlink_to(home / ".agents/skills/unrelated/SKILL.md")
        marker = root / "extension-executed"
        (package / "extension.ts").write_text(
            'import { writeFileSync } from "node:fs"; export default () => writeFileSync('
            + json.dumps(str(marker)) + ', "executed");')
        (package / "package.json").write_text(json.dumps({"name": "test-tools", "pi": {
            "skills": ["skills"], "prompts": ["prompts"], "extensions": ["extension.ts"]}}))
        env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE="1",
                   PI_SKIP_VERSION_CHECK="1", PI_TELEMETRY="0", DAHLIA_PI_BRIDGED_PROVIDERS="")
        # Exercise Pi's real install/remove commands without network or the user's settings.
        subprocess.run([pi, "install", str(package), "--no-approve"], cwd=root, env=env,
                       capture_output=True, check=True, timeout=20)

        def commands(mode):
            bundled = ["--skill", str(ROOT / "apps/macos/Sources/Dahlia/AgentSkills/skill-creator")] if mode in ("chat", "skills") else []
            result = subprocess.run(
                [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills",
                 "--no-context-files", "--no-prompt-templates", "--no-themes", "--no-approve", "--no-session", "--no-tools", *bundled],
                input='{"id":"commands","type":"get_commands"}\n', text=True, capture_output=True,
                cwd=root, env=dict(env, DAHLIA_PI_MODE=mode), check=True, timeout=20)
            records = [json.loads(line) for line in result.stdout.splitlines()]
            response = next(record for record in records if record.get("id") == "commands")
            assert response.get("success"), response
            return {command["name"] for command in response["data"]["commands"]}

        for mode in ("chat", "skills"):
            names = commands(mode)
            assert {"skill:learned", "skill:packaged", "skill:skill-creator", "package-prompt"} <= names, names
            assert "skill:unrelated" not in names and not marker.exists(), names
        for mode in ("control", "summary"):
            names = commands(mode)
            assert not {"skill:learned", "skill:packaged", "skill:skill-creator", "package-prompt"} & names and not marker.exists(), names
        (agent / "settings.json").write_text(json.dumps({"packages": [{"source": str(package), "skills": [], "prompts": []}]}))
        names = commands("chat")
        assert "skill:learned" in names and "skill:packaged" not in names and "package-prompt" not in names, names
        subprocess.run([pi, "remove", str(package), "--no-approve"], cwd=root, env=env,
                       capture_output=True, check=True, timeout=20)
        assert not json.loads((agent / "settings.json").read_text()).get("packages")


def triage_denial_regression(pi):
    """A real tool gate keeps denials in force until the next agent run, including human refusals."""
    with tempfile.NamedTemporaryFile("w", suffix=".py") as mcp:
        mcp.write(MCP_SERVER)
        mcp.flush()
        environment = {"DAHLIA_PI_MCP_COMMAND": json.dumps(["/usr/bin/python3", mcp.name]),
                       "DAHLIA_PI_MCP_SERVERS": json.dumps(["dahlia"])}
        for risk in ("critical", "high"):
            call = {"tool": "mcp__dahlia__update_meeting", "args": {"title": "reviewed"}}
            verdict = {"text": json.dumps({"risk_level": risk, "user_authorization": "low", "outcome": "deny", "rationale": "DENIED_MARKER"})}
            script = [call, verdict, call, verdict, {"text": "done"}, call, {"text": "done"}]
            requests, results, bridge, _ = run(pi, "chat", script, CHAT_ARGUMENTS, environment,
                                               approval_mode="autoReview", approval="decline", triage=True, prompts=2)
            reviews = [request for request in requests if "planned tool call" in json.dumps(request["body"])]
            classifications = [request for request in requests if "questions" in request["body"]]
            assert len(reviews) == 2, (risk, reviews, results)
            assert len(classifications) == 4, (risk, classifications)
            assert len(results) == 3 and "MCP_OK" not in results[0] and "MCP_OK" not in results[1] and results[2] == "MCP_OK", (risk, results)
            approvals = [payload for method, payload in bridge if method == "approval"]
            assert len(approvals) == (0 if risk == "critical" else 2), (risk, approvals)
    print("Pi triage denial regressions passed (critical and user decline, retries and next-run reset)")


def thread_tools(pi):
    calls = [
        ("thread_list", {}), ("thread_search", {"query": "research"}), ("thread_read", {"thread_id": "other"}),
        ("thread_launch", {"title": "Research", "message": "research", "client_request_id": "launch"}),
        ("delegate_task", {"task": "research", "client_request_id": "delegate"}),
        ("task_status", {"task_id": "child"}), ("task_cancel", {"task_id": "child"}),
        ("thread_send", {"thread_id": "other", "message": "continue", "client_request_id": "send"}),
        ("thread_wait", {"thread_id": "other"}), ("thread_interrupt", {"thread_id": "other"}),
        ("thread_update", {"thread_id": "other", "title": "Updated"}),
    ]
    script = [{"tool": name, "args": args} for name, args in calls] + [{"text": "done"}]
    requests, results, bridge, _ = run(pi, "chat", script,
        ["--no-session", "--tools", ",".join(name for name, _ in calls)], {},
        bridge_answers={name: {"ok": True} for name, _ in calls},
        steer_message="HEADLESS_STEER_MARKER")
    assert len(results) == len(calls) and all(json.loads(result)["ok"] for result in results), results
    assert all((name, args) in bridge for name, args in calls), bridge
    assert any("HEADLESS_STEER_MARKER" in json.dumps(request["body"]) for request in requests), requests
    print("Pi thread tools and headless steer passed (11 tools, isolated loopback gateway)")


def schedule_approval_regression(pi):
    """Real Pi must review Dahlia's effective schedule before committing it."""
    effective = {"action": "create", "prompt": "Read saved meetings", "schedule": "30m",
                 "skills": ["meeting-reviewer"], "approved_read_only_tools": ["mcp__dahlia__get_meeting"], "revision": 2}
    challenge = {"request_id": "frozen-schedule", "approval": {
        "kind": "mcpToolCall", "server": "dahlia", "tool": "cronjob", "arguments": effective}}
    for mode, risk, outcome, decision, allowed, asks in [
        ("autoReview", "low", "allow", "decline", True, False),
        ("autoReview", "high", "deny", "accept", True, True),
        ("autoReview", "high", "deny", "decline", False, True),
        ("autoReview", "critical", "deny", "accept", False, False),
        ("autoReview", "unknown", "deny", "decline", False, True),
        ("ask", None, None, "accept", True, True),
        ("fullAccess", None, None, "decline", False, True),
    ]:
        steps = [{"tool": "cronjob", "args": {"action": "update", "job_id": "saved"}}]
        if risk:
            steps.append({"text": json.dumps({"risk_level": risk, "user_authorization": "high",
                                             "outcome": outcome, "rationale": "SCHEDULE_REVIEW"})})
            if risk == "unknown":
                steps[-1] = {"error": "invalid API key"}
        steps.append({"text": "done"})
        requests, results, bridge, _ = run(
            pi, "chat", steps, ["--no-session", "--tools", "cronjob"], {},
            approval_mode=mode, approval=decision,
            bridge_answers={"cronjob": challenge, "cronjobCommit": {"success": allowed}})
        commits = [payload for method, payload in bridge if method == "cronjobCommit"]
        assert commits == [{"request_id": "frozen-schedule", "approved": allowed}], (mode, risk, results, bridge)
        approvals = [payload for method, payload in bridge if method == "approval"]
        assert bool(approvals) == asks, (mode, risk, bridge)
        if approvals:
            assert approvals[0]["arguments"] == effective, approvals
        if risk:
            assert "Read saved meetings" in json.dumps(requests[1]["body"]), requests
            assert "approved_read_only_tools" in json.dumps(requests[1]["body"]), requests
        else:
            assert not any(method == "reviewModel" for method, _ in bridge), bridge
    # Listing never enters the gate.
    _, _, bridge, _ = run(pi, "chat", [{"tool": "cronjob", "args": {"action": "list"}}, {"text": "done"}],
                          ["--no-session", "--tools", "cronjob"], {}, bridge_answers={"cronjob": []})
    assert not any(method in {"approvalMode", "approval", "cronjobCommit"} for method, _ in bridge), bridge
    print("PASS: schedule approval modes, review fallback, critical denial, frozen revision and read-only listing")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pi", default="pi")
    parser.add_argument("--only-schedules", action="store_true")
    parser.add_argument("--only-web-access", action="store_true")
    parser.add_argument("--web-access-package", help="Installed pi-web-access 0.47.0 package directory; also test the real MCP worker offline")
    args = parser.parse_args()
    pi = args.pi
    web_access_package = args.web_access_package
    assert Path(os.environ.get("DAHLIA_PI_AUTO_REVIEW", "")).is_file(), "Set DAHLIA_PI_AUTO_REVIEW to pi-auto-review's index.ts"
    if args.only_web_access:
        web_access_regression(pi, web_access_package)
        return
    schedule_approval_regression(pi)
    if args.only_schedules:
        return
    thread_tools(pi)
    triage_denial_regression(pi)
    package_resources(pi)
    curator_store_snapshots(pi)
    _, results, bridge, _ = run(
        pi, "chat", [{"tool": "dah_create_backup", "args": {"workspace_id": "ws_test"}}, {"text": "done"}],
        ["--no-session", "--tools", "dah_create_backup"], {})
    assert ("createBackup", {"workspace_id": "ws_test"}) in bridge, bridge
    assert json.loads(results[0])["path"] == "/tmp/Dahlia-Backup-test.tar.gz", results

    # Keywords Claude or Gemini cannot take, and a property named like one, which must stay.
    full_schema = {"type": "object", "additionalProperties": False, "required": ["a", "pattern"], "properties": {
        "a": {"type": "string", "minLength": 1, "maxLength": 5, "pattern": "^x+$"},
        "pattern": {"type": "array", "minItems": 1, "maxItems": 3, "items": {"type": "integer", "minimum": 0}}}}

    claude_expected = dict(full_schema, properties={
        "a": {"type": "string", "pattern": "^x+$"},
        "pattern": {"type": "array", "minItems": 1, "items": {"type": "integer"}}})
    gemini_expected = dict(full_schema, properties={
        "a": {"type": "string"},
        "pattern": {"type": "array", "minItems": 1, "maxItems": 3, "items": {"type": "integer", "minimum": 0}}})

    # Where each API carries the enforced schema in the request body, and the schema it should carry there.
    def openai_schema(body):
        format_ = body.get("text", {}).get("format")
        return format_ and format_["strict"] and format_["schema"]

    def claude_schema(body):
        format_ = body.get("output_config", {}).get("format")
        # Pi's adaptive-thinking effort survives next to the format.
        assert format_ is None or body["output_config"].get("effort") == "high", body.get("output_config")
        return format_ and format_["type"] == "json_schema" and format_["schema"]

    def gemini_schema(body):
        config = body.get("generationConfig", {})
        return config.get("responseJsonSchema") and config["responseMimeType"] == "application/json" and config["responseJsonSchema"]

    routes = [("openai-responses", openai_schema, full_schema, None),
              ("anthropic-messages", claude_schema, claude_expected, {"forceAdaptiveThinking": True}),
              ("google-generative-ai", gemini_schema, gemini_expected, None)]
    with tempfile.NamedTemporaryFile("w", suffix=".json") as schema:
        json.dump(full_schema, schema)
        schema.flush()
        for api, sent_schema, expected, compat in routes:
            for strict in ("1", "0"):
                requests, _, bridge, _ = run(pi, "summary", [{"text": '{"a":"日本語"}'}],
                                             ["--no-session", "--no-tools", "--thinking", "high"],
                                             {"PI_OUTPUT_JSON_SCHEMA": schema.name, "PI_OUTPUT_STRICT_SCHEMA": strict},
                                             api=api, compat=compat)
                assert requests[0]["auth"] == "Bearer synthetic-token", requests[0]["auth"]
                assert bridge[0] == ("token", {"provider": "databricks"}), bridge
                body = requests[0]["body"]
                assert sent_schema(body) == (expected if strict == "1" else None), (api, strict, body)
                assert "tools" not in body or not body["tools"]

    with tempfile.NamedTemporaryFile("w", suffix=".py") as mcp:
        mcp.write(MCP_SERVER)
        mcp.flush()
        environment = {"DAHLIA_PI_MCP_COMMAND": json.dumps(["/usr/bin/python3", mcp.name]),
                       "DAHLIA_PI_MCP_SERVERS": json.dumps(["dahlia"])}

        def chat(*steps, **options):
            profile = options.pop("profile", "interactive")
            names = options.pop("tool_names", CHAT_ARGUMENTS[-1])
            isolated = dict(environment, DAHLIA_PI_PROFILE=profile, DAHLIA_PI_MEMORY_ENABLED="1",
                            DAHLIA_PI_ALLOWED_TOOLS=json.dumps(["mcp__dahlia__get_meeting"]))
            if options.pop("missing_reviewer", False):
                isolated["DAHLIA_PI_AUTO_REVIEW"] = "/nonexistent/pi-auto-review/index.ts"
            web_access = options.pop("web_access", None)
            return run(pi, "chat", [*steps, {"text": "done"}], [*CHAT_ARGUMENTS[:-2], "--tools", names], isolated,
                       web_access=web_access, **options)

        # Immutable execution profiles remain ceilings even under fullAccess and when a forbidden schema is advertised.
        for profile in ("scheduled", "review"):
            _, results, bridge_calls, _ = chat({"tool": "bash", "args": {"command": "echo FORBIDDEN"}},
                                              profile=profile, approval_mode="fullAccess")
            assert "FORBIDDEN" not in results[0] and ("unavailable" in results[0] or "only read" in results[0]), results
            assert not any(method == "approval" for method, _ in bridge_calls), bridge_calls
        _, results, bridge_calls, _ = chat({"tool": "memory", "args": {"target": "user", "operations": [{"action": "add", "content": "User prefers Japanese"}]}},
                                          profile="scheduled", tool_names="memory", approval_mode="fullAccess")
        assert "only read" in results[0] and not any(method == "memory" for method, _ in bridge_calls), (results, bridge_calls)
        _, results, bridge_calls, _ = chat({"tool": "memory", "args": {"target": "user", "operations": [{"action": "add", "content": "User prefers Japanese"}]}},
                                          tool_names="memory", bridge_answers={"memory": {"success": True}})
        assert any(method == "memory" for method, _ in bridge_calls), (results, bridge_calls)
        _, results, bridge_calls, _ = chat({"tool": "mcp__dahlia__update_meeting"}, profile="scheduled", approval_mode="fullAccess")
        assert "not approved" in results[0] and "MCP_OK" not in results[0], results
        _, results, bridge_calls, _ = chat({"tool": "mcp__dahlia__get_meeting"}, profile="scheduled", bridge_answers={"scheduledTool": True})
        assert "MCP_OK" in results[0] and any(method == "scheduledTool" for method, _ in bridge_calls), (results, bridge_calls)

        # Budget exhaustion must abort Pi; throwing from a hook alone is logged and ignored by Pi.
        memory_call = {"tool": "memory", "args": {"target": "user", "operations": [{"action": "add", "content": "Synthetic fact"}]}}
        requests, _, _, _ = chat(*([memory_call] * 18), profile="review", tool_names="memory", bridge_answers={"memory": {"success": True}})
        assert len(requests) == 16, len(requests)
        requests, _, _, _ = chat(dict(memory_call, input_tokens=75000), profile="review", tool_names="memory", bridge_answers={"memory": {"success": True}})
        assert len(requests) == 1, len(requests)

        requests, results, _, _ = chat({"tool": "read", "args": {"path": "inside.txt"}})
        names = [tool.get("name") for tool in requests[0]["body"].get("tools", [])]
        assert {"read", "ls", "bash", "mcp__dahlia__get_meeting"} <= set(names), names
        assert "INSIDE_MARKER" in results[0], results
        # Dahlia's skills are readable, and an image is still recognized when read through the sandbox.
        _, results, _, _ = chat({"tool": "read", "args": {"path": "../skills/SKILL.md"}}, {"tool": "read", "args": {"path": "pixel.png"}})
        assert "SKILL_MARKER" in results[0] and "image/png" in results[1], results

        # Listing runs in the sandbox too: a folder is marked, and folders outside the workspace are not listed.
        _, results, _, _ = chat({"tool": "bash", "args": {"command": "mkdir sub"}}, {"tool": "ls", "args": {"path": "."}},
                                {"tool": "ls", "args": {"path": "../agent"}}, {"tool": "ls", "args": {"path": "~"}})
        assert "sub/" in results[1] and "inside.txt" in results[1], results
        assert "auth.json" not in results[2] and "Library" not in results[3], results

        # Every spelling of a path outside the workspace stays unreadable, including a symlink out of it.
        for path in ["../agent/auth.json", "@../agent/auth.json", "~/.zshrc", "link", "../tmp/../agent/auth.json"]:
            _, results, _, _ = chat({"tool": "read", "args": {"path": path}})
            assert "SECRET_MARKER" not in results[0] and ("not permitted" in results[0] or "Cannot read" in results[0]), (path, results)

        # Chat changes files only in its working folder; a new file's folders are made on the way.
        _, results, _, _ = chat({"tool": "write", "args": {"path": "notes/new.txt", "content": "WRITTEN"}},
                                {"tool": "edit", "args": {"path": "notes/new.txt", "edits": [{"oldText": "WRITTEN", "newText": "EDITED"}]}},
                                {"tool": "read", "args": {"path": "notes/new.txt"}})
        assert "EDITED" in results[2], results
        for tool, args in [("write", {"path": "../outside.txt", "content": "CHANGED"}),
                           ("write", {"path": "link", "content": "CHANGED"}),
                           ("write", {"path": "../agent/new/outside.txt", "content": "CHANGED"}),
                           ("edit", {"path": "../agent/auth.json", "edits": [{"oldText": "SECRET_MARKER", "newText": "CHANGED"}]})]:
            _, results, _, outside = chat({"tool": tool, "args": args})
            assert not outside and ("not permitted" in results[0] or "Cannot read" in results[0]), (tool, args, results)
        web_access_regression(pi, web_access_package)
        # A link a command makes to a file that does not exist yet cannot carry a write out of the working folder.
        _, results, _, outside = chat({"tool": "bash", "args": {"command": "ln -s ../outside.txt dangling"}},
                                      {"tool": "write", "args": {"path": "dangling", "content": "CHANGED"}})
        assert not outside and "not permitted" in results[1], results
        # A refused write larger than a pipe buffer fails like any other and leaves Pi running; git works without the real home.
        _, results, _, outside = chat({"tool": "write", "args": {"path": "../outside.txt", "content": "CHANGED" * 100000}},
                                      {"tool": "bash", "args": {"command": "yes | head -c 400000; git init -q . && echo GIT_OK"}})
        assert not outside and "not permitted" in results[0] and "GIT_OK" in results[1], results
        # Pi saves a long output in chat's temporary folder, where the sandboxed read can open it.
        log = re.search(r"Full output: (\S+/pi-tmp/[^\]\s]+)", results[1])
        assert log, results[1][-300:]
        # Pi loads its transpiled extensions from its own temporary folder, so chat reads that folder but never writes it.
        _, results, _, _ = chat({"tool": "bash", "args": {"command": "ls $TMPDIR/../pi-tmp/jiti && echo x > $TMPDIR/../pi-tmp/jiti/planted.mjs"}})
        assert "dahlia" in results[0] and "not permitted" in results[0], results

        # Bash actually executes, including sqlite3 and a quoted here-document, inside the Seatbelt write boundary.
        _, results, bridge, _ = chat({"tool": "bash", "args": {"command": "echo BASH_MARKER > bash.txt && cat bash.txt"}},
                                     {"tool": "bash", "args": {"command": "sqlite3 -readonly ../dahlia.sqlite 'SELECT value FROM debug'"}})
        assert "BASH_MARKER" in results[0] and "SQLITE_MARKER" in results[1], results
        assert not any(method == "approval" for method, _ in bridge), bridge
        _, results, _, outside = chat({"tool": "bash", "args": {"command": "echo x > ../outside.txt"}},
                                      {"tool": "bash", "args": {"command": "sqlite3 ../dahlia.sqlite 'DELETE FROM debug'"}},
                                      {"tool": "bash", "args": {"command": "sqlite3 -readonly ../dahlia.sqlite 'SELECT value FROM debug'"}})
        assert not outside and "SQLITE_MARKER" in results[2], results
        assert "readonly" in results[1].lower() or "authorization denied" in results[1].lower(), results
        # Pi is outside the sandbox, so a command reads neither Pi's sign-ins nor the user's secret variables.
        _, results, _, _ = chat({"tool": "bash", "args": {"command": "cat ../agent/auth.json; env; cat <<'END'\nit's $HOME\nEND"}})
        assert "it's $HOME" in results[0] and "PI_CODING_AGENT_DIR" in results[0], results
        assert "SECRET_MARKER" not in results[0], results

        _, results, bridge, _ = chat({"tool": "mcp__dahlia__get_meeting"})
        assert results == ["MCP_OK"] and not any(method == "approval" for method, _ in bridge), (results, bridge)
        _, results, bridge, _ = chat({"tool": "mcp__dahlia__update_meeting", "args": {"title": "x"}})
        approvals = [payload for method, payload in bridge if method == "approval"]
        assert [(p["kind"], p["tool"]) for p in approvals] == [("mcpToolCall", "update_meeting")], bridge
        assert results == ["MCP_OK"], results
        _, results, _, _ = chat({"tool": "mcp__dahlia__update_meeting"}, approval="decline")
        assert "declined" in results[0], results
        _, results, bridge, _ = chat({"tool": "mcp__dahlia__update_meeting"}, approval_mode="fullAccess")
        assert results == ["MCP_OK"] and not any(method == "approval" for method, _ in bridge), (results, bridge)

        # Native preflight rejection stops every approval mode before review or execution.
        for mode in ("ask", "autoReview", "fullAccess"):
            requests, results, bridge, _ = chat(
                {"tool": "mcp__dahlia__update_meeting", "args": {"title": "bounded"}},
                approval_mode=mode, bridge_answers={"approvalCheck": False})
            assert "cannot be approved" in results[0] and "MCP_OK" not in results, (mode, results)
            assert len(requests) == 2, (mode, requests)
            assert not any(method in {"reviewModel", "reviewTriage", "approval"} for method, _ in bridge), (mode, bridge)

        # Auto review uses the account's provider and a real review request before any MCP mutation.
        for risk, outcome in [("low", "allow"), ("high", "deny"), ("critical", "deny"), ("unknown", "deny")]:
            verdict = json.dumps({"risk_level": risk, "user_authorization": "low", "outcome": outcome, "rationale": "REVIEW_MARKER"})
            steps = [{"tool": "mcp__dahlia__update_meeting", "args": {"title": "reviewed"}}, {"text": verdict}]
            if risk == "unknown":
                # A permanent failure (no retry) falls back to the human, never silently allows.
                steps[1] = {"error": "invalid API key"}
            requests, results, bridge, _ = chat(*steps, approval_mode="autoReview", approval="decline")
            approvals = [payload for method, payload in bridge if method == "approval"]
            assert len(requests) == 3, (risk, requests)
            assert requests[1]["auth"] == "Bearer synthetic-token", requests[1]
            assert "planned tool call" in json.dumps(requests[1]["body"]), requests[1]
            assert requests[1]["body"]["text"]["format"]["type"] == "json_schema", requests[1]
            if outcome == "allow":
                assert results == ["MCP_OK"] and not approvals, (results, bridge)
            elif risk == "critical":
                assert "critical" in results[0] and not approvals, (results, bridge)
            else:
                assert "declined" in results[0] and approvals[0]["reason"].startswith("MCP AI review"), (results, bridge)
        _, results, bridge, _ = chat({"tool": "mcp__dahlia__update_meeting"},
                                    {"text": json.dumps({"risk_level": "high", "user_authorization": "low", "outcome": "deny", "rationale": "Ask the user"})},
                                    approval_mode="autoReview", approval="accept")
        assert results == ["MCP_OK"] and any(method == "approval" for method, _ in bridge), (results, bridge)
        # Without the pi-auto-review plugin, Auto review asks as Always ask does, with no review request.
        requests, results, bridge, _ = chat({"tool": "mcp__dahlia__update_meeting"}, approval_mode="autoReview",
                                            approval="decline", missing_reviewer=True)
        assert "declined" in results[0] and len(requests) == 2, (results, requests)
        assert any(method == "approval" for method, _ in bridge) and not any(method == "reviewModel" for method, _ in bridge), bridge

    # Every model API Dahlia configures for a bridged provider gets the account's token.
    # The Databricks templates' APIs, plus the Dahlia Server's (OpenAI Responses).
    catalog = json.loads((ROOT / "apps/macos/Sources/Dahlia/PiExtension/databricks-models.json").read_text())
    apis = {template["api"] for template in catalog["templates"] if "api" in template} | {"openai-responses"}
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

    # A registered MCP signs in to its workspace with the extension's OAuth flow, and Pi stores the credential. An
    # mcp.json MCP that names that provider in `auth.provider` gets its token and reaches the first prompt; one without
    # it never does. Only read-only gateway tools skip approval.
    grants, resources = [], []
    credential_requests = []
    metadata_response = {"status": 200, "body": {"name": "mcp-services/main.default.notion", "comment": "Search Notion pages"}}
    workspace = oidc(grants, resources=resources, credential_requests=credential_requests, metadata_response=metadata_response)
    origin = f"http://127.0.0.1:{workspace.server_port}"
    # The provider is the workspace host. The credential keeps the workspace and client, so any process refreshes it.
    provider = f"127.0.0.1:{workspace.server_port}"
    auth = mcp_login(pi, origin)
    credential = auth[provider]
    assert credential["type"] == "oauth" and credential["access"] == "mcp-access-1" and credential["refresh"] == "refresh-1", auth
    assert (credential["origin"], credential["clientId"], credential["scopes"]) == (origin, "databricks-cli", "ai-gateway unity-catalog offline_access"), auth
    assert grants == ["authorization_code"], grants

    # Listing follows pages and checks credentials only for explicitly enabled services.
    enabled_services = "system.ai.github,system.ai.gmail,system.ai.slack,system.ai.atlassian,system.ai.unsupported"
    messages, _ = control(pi, f"/databricks-mcp-services {origin} --enabled {enabled_services}", auth=auth)
    assert messages == ['databricks:mcp_services [{"name":"system.ai.atlassian","signInState":"unknown"},{"name":"system.ai.github","comment":"Search repositories","signInState":"signedIn"},{"name":"system.ai.gmail","signInState":"signInRequired"},{"name":"system.ai.slack","signInState":"signInRequired"},{"name":"system.ai.unsupported","signInState":"unknown"}]'], messages
    assert set(credential_requests) == set(enabled_services.split(",")), credential_requests
    credential_requests.clear()
    messages, _ = control(pi, f"/databricks-mcp-services {origin}", auth=auth)
    assert credential_requests == [], credential_requests
    assert all(service["signInState"] == "unknown" for service in json.loads(messages[0].partition(" ")[2])), messages
    messages, _ = control(pi, f"/databricks-mcp-services {origin} --enabled system.ai.github", auth=auth)
    assert credential_requests == ["system.ai.github"], credential_requests
    assert [service["name"] for service in json.loads(messages[0].partition(" ")[2]) if service["signInState"] == "signedIn"] == ["system.ai.github"]
    credential_requests.clear()
    messages, _ = control(pi, f"/databricks-mcp-services {origin} --enabled main.default.notion", auth=auth)
    assert credential_requests == ["main.default.notion"], credential_requests
    services = json.loads(messages[0].partition(" ")[2])
    assert services[0] == {"name": "main.default.notion", "comment": "Search Notion pages", "signInState": "signedIn"}, services
    assert all(service["signInState"] == "unknown" for service in services[1:]), services
    for status in [403, 500]:
        metadata_response.update(status=status, body={"error_code": "UNAVAILABLE"})
        messages, _ = control(pi, f"/databricks-mcp-services {origin} --enabled main.default.notion", auth=auth)
        service = json.loads(messages[0].partition(" ")[2])[0]
        assert service == {"name": "main.default.notion", "metadataUnavailable": True, "signInState": "signedIn"}, service
    metadata_response.update(status=200, body={"name": "mcp-services/main.default.notion"})
    messages, _ = control(pi, f"/databricks-mcp-services {origin} --enabled main.default.notion", auth=auth)
    service = json.loads(messages[0].partition(" ")[2])[0]
    assert service == {"name": "main.default.notion", "signInState": "signedIn"}, service
    messages, _ = control(pi, f"/databricks-mcp-services {origin}", auth={})
    assert messages == ["databricks:mcp_services_sign_in_required"], messages
    # The account's own workspace lists with its bridged sign-in, which Dahlia holds.
    messages, _ = control(pi, f"/databricks-mcp-services {origin} --provider databricks --enabled {enabled_services}", auth={},
                          environment={"DAHLIA_PI_BRIDGED_PROVIDERS": "databricks"})
    assert messages == ['databricks:mcp_services [{"name":"system.ai.atlassian","signInState":"unknown"},{"name":"system.ai.github","comment":"Search repositories","signInState":"signedIn"},{"name":"system.ai.gmail","signInState":"signInRequired"},{"name":"system.ai.slack","signInState":"signInRequired"},{"name":"system.ai.unsupported","signInState":"unknown"}]'], messages
    # Listing the gateway's models keeps only what Dahlia reads (the name, API types, and capabilities), for the
    # workspace's sign-in or the account's bridged one.
    haiku = {"name": "model-services/system.ai.claude-haiku-5-5", "supported_api_types": ["anthropic/v1/messages"],
             "capabilities": {"function_calling": True, "image_input": True}}
    messages, _ = control(pi, f"/databricks-model-services {origin}", auth=auth)
    assert [json.loads(message.partition(" ")[2]) for message in messages] == [[haiku]], messages
    messages, _ = control(pi, f"/databricks-model-services {origin} --provider databricks", auth={},
                          environment={"DAHLIA_PI_BRIDGED_PROVIDERS": "databricks"})
    assert [json.loads(message.partition(" ")[2]) for message in messages] == [[haiku]], messages
    messages, _ = control(pi, f"/databricks-model-services {origin}", auth={})
    assert messages == ["databricks:model_services_sign_in_required"], messages
    # A workspace's models in models.json belong to its sign-in's provider, which dahlia.ts registers from that file.
    listed = list_models(pi, auth, {provider: {"name": provider, "baseUrl": origin, "authHeader": True, "models": [{
        "id": "system.ai.claude-haiku-5-5", "name": "Claude Haiku 5.5", "api": "anthropic-messages",
        "baseUrl": f"{origin}/ai-gateway/anthropic", "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]}})
    assert f"{provider} system.ai.claude-haiku-5-5" in listed, listed
    # Signing in to a service's connection names the service as the resource and exchanges no code.
    messages, _ = control(pi, f"/databricks-connection-login {origin} system.ai.github", auth={}, browser=True)
    assert messages[-1] == "databricks:connection_login_succeeded", messages
    assert resources == [None, f"{origin}/ai-gateway/mcp-services/system.ai.github"], resources
    assert grants == ["authorization_code"], grants

    # A refusal carries Databricks' reason, such as a missing scope.
    messages, _ = control(pi, f"/databricks-mcp-services {origin} --provider databricks --enabled {enabled_services}", auth={},
                          environment={"DAHLIA_PI_BRIDGED_PROVIDERS": "databricks"}, bridge_token="denied")
    assert messages == ["databricks:mcp_services_failed Listing MCP services failed (HTTP 403, PERMISSION_DENIED: missing scope unity-catalog)"], messages

    # A client the organization registered signs in with its own ID and exact redirect URL.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        callback_port = probe.getsockname()[1]
    redirect = f"http://localhost:{callback_port}/ai-devtools-workspace-oauth"
    custom_grants = []
    custom = oidc(custom_grants, client_id="custom-client", redirect=redirect, scopes={"all-apis", "offline_access"})
    custom_origin = f"http://127.0.0.1:{custom.server_port}"
    custom_auth = mcp_login(pi, f"{custom_origin} --client-id custom-client --redirect-url {redirect} --scopes offline_access,all-apis")
    custom_credential = custom_auth[f"127.0.0.1:{custom.server_port}"]
    assert (custom_credential["clientId"], custom_credential["redirectUrl"]) == ("custom-client", redirect), custom_auth
    assert custom_grants == ["authorization_code"], custom_grants
    custom.shutdown()

    authorizations, foreign = [], []
    server, foreign_server = http_mcp(authorizations), http_mcp(foreign)
    mcp_servers = {"gmail": {"url": f"http://127.0.0.1:{server.server_port}/mcp", "exposure": "direct",
                             "auth": {"provider": provider}},
                   "foreign": {"url": f"http://127.0.0.1:{foreign_server.server_port}/mcp", "exposure": "direct"}}
    arguments = ["--no-session", *CHAT_EXTENSIONS, "--tools", "read,mcp__gmail__*"]

    def gateway_chat(*steps, arguments=arguments, auth=auth, **options):
        return run(pi, "chat", [*steps, {"text": "done"}], arguments, {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"])},
                   mcp_servers=mcp_servers, auth=auth, **options)

    requests, results, bridge, _ = gateway_chat({"tool": "mcp__gmail__search_messages"})
    # With both extensions loaded, dahlia.ts still gets session_start: the model request carries the bridged token.
    assert requests[0]["auth"] == "Bearer synthetic-token", requests[0]["auth"]
    assert ("token", {"provider": "databricks"}) in bridge, bridge
    names = [tool.get("name") for tool in requests[0]["body"].get("tools", [])]
    assert {"mcp__gmail__search_messages", "mcp__gmail__send_message"} <= set(names), names
    assert "mcp__foreign__search_messages" not in names, names
    assert authorizations and set(authorizations) == {"Bearer mcp-access-1"}, authorizations
    assert foreign and set(foreign) == {None}, foreign
    assert results == ["GATEWAY_OK"] and not any(method == "approval" for method, _ in bridge), (results, bridge)
    _, results, bridge, _ = gateway_chat({"tool": "mcp__gmail__send_message"}, approval="decline")
    approvals = [payload for method, payload in bridge if method == "approval"]
    assert [(p["server"], p["tool"]) for p in approvals] == [("gmail", "send_message")], bridge
    assert "declined" in results[0], results
    # A server Dahlia did not register stays blocked even if its tools get past --tools.
    _, results, bridge, _ = gateway_chat({"tool": "mcp__foreign__search_messages"}, approval_mode="fullAccess",
                                         arguments=["--no-session", *CHAT_EXTENSIONS, "--tools", "read,mcp__gmail__*,mcp__foreign__*"])
    assert "not available" in results[0] and "GATEWAY_OK" not in results[0], results

    # Intake reads its one source and records events; it cannot write to the source or read files, even under fullAccess.
    record = {"items": [{"key": "m1", "topic": "t1", "note": "A reply is needed", "ref": {"messageId": "m1"}}]}
    _, results, bridge, _ = run(
        pi, "chat",
        [{"tool": "mcp__gmail__search_messages"}, {"tool": "event_record", "args": record}, {"tool": "mcp__gmail__send_message"},
         {"tool": "read", "args": {"path": "inside.txt"}}, {"text": "done"}],
        ["--no-session", *CHAT_EXTENSIONS, "--tools", "event_record,read,mcp__gmail__*"],
        {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"]), "DAHLIA_PI_PROFILE": "intake"}, mcp_servers=mcp_servers, auth=auth,
        approval_mode="fullAccess", bridge_answers={"eventRecord": {"success": True}, "intakeSeen": True})
    assert results[0] == "GATEWAY_OK" and ("eventRecord", record) in bridge, (results, bridge)
    assert [call for call in bridge if call[0] == "intakeSeen"] == [("intakeSeen", {"ids": []})], bridge
    assert "only read its source" in results[2] and "GATEWAY_OK" not in results[2], results
    assert "only read its source" in results[3] and "INSIDE_MARKER" not in results[3], results
    assert not any(method == "approval" for method, _ in bridge), bridge
    # Super Agent routes through ordinary thread tools, but has no external MCP or command access, even under fullAccess.
    route = {"title": "Follow up", "message": "Read the event", "event_ids": ["e1"], "client_request_id": "launch"}
    bot_calls = [("calendar_read", {}), ("remind", {"at": "2030-01-01T08:00:00Z", "note": "Follow up"}), ("inbox_read", {}), ("event_close", {"event_ids": ["e2"]}),
                 ("item_create", {"kind": "report", "title": "Read it"}),
                 ("task_finish", {"thread_id": "task", "status": "done"}), ("soul_write", {"text": "Be concise"})]
    _, results, bridge, _ = run(
        pi, "chat", [{"tool": "mcp__gmail__search_messages"}, {"tool": "thread_launch", "args": route},
                     {"tool": "read", "args": {"path": "inside.txt"}},
                     {"tool": "write", "args": {"path": "SOUL.md", "content": "CHANGED"}},
                     {"tool": "bash", "args": {"command": "echo COMMAND_MARKER"}}]
                    + [{"tool": name, "args": args} for name, args in bot_calls] + [{"text": "done"}],
        ["--no-session", *CHAT_EXTENSIONS, "--tools", "thread_launch,read,write,bash,mcp__gmail__*," + ",".join(name for name, _ in bot_calls)],
        {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"]), "DAHLIA_PI_PROFILE": "bot"}, mcp_servers=mcp_servers, auth=auth,
        approval_mode="fullAccess", bridge_answers={"botTool": {"success": True}, "thread_launch": {"success": True}})
    assert "only reads" in results[0] and "GATEWAY_OK" not in results[0], results
    assert ("thread_launch", route) in bridge, bridge
    assert "INSIDE_MARKER" in results[2] and "soul_write" in results[3], results
    assert "only reads" in results[4] and "COMMAND_MARKER" not in results[4], results
    assert [call for call in bridge if call[0] == "botTool"] == [("botTool", {"name": name, "args": args}) for name, args in bot_calls], bridge
    assert not any(method == "approval" for method, _ in bridge), bridge
    # Bot file operations cannot use runtime read exceptions, alternate spellings or symlinks to leave home.
    denied = [("read", {"path": path}) for path in
              ("../skills/SKILL.md", "@../skills/SKILL.md", "../tmp/shared.txt", "shared-link")]
    denied += [("ls", {"path": "../tmp"}), ("write", {"path": "protected-alias", "content": "CHANGED"})]
    inside = [("write", {"path": "notes/new.txt", "content": "WRITTEN"}),
              ("edit", {"path": "notes/new.txt", "edits": [{"oldText": "WRITTEN", "newText": "EDITED"}]}),
              ("read", {"path": "notes/new.txt"}), ("read", {"path": "pixel.png"}), ("read", {"path": "SOUL.md"})]
    _, results, _, _ = run(pi, "chat", [{"tool": name, "args": args} for name, args in denied + inside] + [{"text": "done"}],
        ["--no-session", "--tools", "read,ls,write,edit"], {"DAHLIA_PI_PROFILE": "bot"}, approval_mode="fullAccess")
    assert all("SKILL_MARKER" not in result and "OTHER_CHAT_MARKER" not in result for result in results[:len(denied)]), results
    assert all("home" in result or "Cannot read" in result or "soul_write" in result for result in results[:len(denied)]), results
    assert "EDITED" in results[-3] and "image/png" in results[-2] and "PROTECTED_MARKER" in results[-1], results
    # Ordinary task threads use chat's usual MCP approvals and commands, instead of the removed Worker restrictions.
    _, results, bridge, _ = gateway_chat(
        {"tool": "mcp__gmail__send_message"}, {"tool": "bash", "args": {"command": "echo TASK_COMMAND_MARKER"}},
        approval_mode="fullAccess", arguments=["--no-session", *CHAT_EXTENSIONS, "--tools", "bash,mcp__gmail__*"])
    assert results[0] == "GATEWAY_OK" and "TASK_COMMAND_MARKER" in results[1], results
    # Bot-only tools are not registered in ordinary chats.
    _, _, bridge, _ = run(pi, "chat", [{"tool": "inbox_read"}, {"text": "done"}],
                           ["--no-session", "--tools", "inbox_read"], {}, bridge_answers={"botTool": {"success": True}})
    assert not any(method == "botTool" for method, _ in bridge), bridge

    # A listing of messages tells Dahlia which items intake read; thread listings and other profiles do not.
    listing = {"probe_items": [{"id": "m1", "threadId": "t1"}, {"id": "m2", "threadId": "t1"}, {"id": "t9"}]}
    def request_key(args):
        request = dict(args)
        if request.get("cursor") == "":
            del request["cursor"]
        return json.dumps(["mcp__gmail__search_messages", request], sort_keys=True, separators=(",", ":"))

    listed = {"ids": ["m1", "m2"], "pages": [{"requestKey": request_key(listing), "nextRequestKey": "", "root": True, "hasMore": False}]}
    for profile, expected in (("intake", [("intakeSeen", listed)]), ("interactive", [])):
        _, results, bridge, _ = run(
            pi, "chat", [{"tool": "mcp__gmail__search_messages", "args": listing}, {"text": "done"}],
            ["--no-session", *CHAT_EXTENSIONS, "--tools", "event_record,mcp__gmail__*"],
            {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"]), "DAHLIA_PI_PROFILE": profile}, mcp_servers=mcp_servers, auth=auth,
            bridge_answers={"intakeSeen": True})
        assert [call for call in bridge if call[0] == "intakeSeen"] == expected, (profile, bridge)

    # An MCP error followed by a normal assistant ending must still reach the native cursor gate. A later success
    # does not erase the earlier failure: the native run retries the whole range.
    _, results, bridge, _ = run(
        pi, "chat", [{"tool": "mcp__gmail__search_messages", "args": {"probe_error": True}},
                     {"tool": "mcp__gmail__search_messages", "args": listing}, {"text": "Could not read another page"}],
        ["--no-session", *CHAT_EXTENSIONS, "--tools", "event_record,mcp__gmail__*"],
        {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"]), "DAHLIA_PI_PROFILE": "intake"}, mcp_servers=mcp_servers, auth=auth,
        bridge_answers={"intakeReadFailed": True, "intakeSeen": True})
    assert [call for call in bridge if call[0] in ("intakeReadFailed", "intakeSeen")] == [
        ("intakeReadFailed", {}), ("intakeSeen", listed)], bridge

    # The same query at different page sizes creates independent exact-request paths. Response controls stay
    # server-side, so a response's items/cursor cannot contaminate the identity of the request that produced it.
    small = {"query": "after:2026/11/20", "max_results": 1, "probe_case": "pagination", "filter": {"b": 2, "a": 1}}
    page_args = [small, {"query": "other", "probe_case": "pagination"},
                 {"filter": {"a": 1, "b": 2}, "cursor": "p2", "probe_case": "pagination", "max_results": 1, "query": small["query"]},
                 dict(small, max_results=100), dict(small, cursor="p3"),
                 dict(small, max_results=100, filter={"a": 9, "b": 2})]
    _, _, bridge, _ = run(
        pi, "chat", [{"tool": "mcp__gmail__search_messages", "args": args} for args in page_args] + [{"text": "done"}],
        ["--no-session", *CHAT_EXTENSIONS, "--tools", "event_record,mcp__gmail__*"],
        {"DAHLIA_PI_MCP_SERVERS": json.dumps(["gmail"]), "DAHLIA_PI_PROFILE": "intake"}, mcp_servers=mcp_servers, auth=auth,
        bridge_answers={"intakeSeen": True})
    pages = [payload["pages"][0] for method, payload in bridge if method == "intakeSeen"]
    expected_next = ["p2", "", "p3", "", "", ""]
    assert pages == [{"requestKey": request_key(args),
                      "nextRequestKey": request_key(dict(args, cursor=next_cursor)) if next_cursor else "",
                      "root": not args.get("cursor"), "hasMore": bool(next_cursor)}
                     for args, next_cursor in zip(page_args, expected_next)], pages
    assert pages[0]["nextRequestKey"] == pages[2]["requestKey"], pages  # cursor and recursive key ordering only
    assert len({pages[index]["requestKey"] for index in [0, 3, 5]}) == 3, pages  # every shaping argument retained

    # An expired token is refreshed once with the stored refresh token, which Databricks may keep.
    authorizations.clear()
    expired = {provider: dict(credential, expires=1)}
    _, results, _, _ = gateway_chat({"tool": "mcp__gmail__search_messages"}, auth=expired)
    assert results == ["GATEWAY_OK"] and set(authorizations) == {"Bearer mcp-access-2"}, (results, authorizations)
    assert grants == ["authorization_code", "refresh_token"], grants
    server.shutdown()
    foreign_server.shutdown()
    workspace.shutdown()
    print("Pi extension tests passed (token bridge, strict schema on OpenAI/Claude/Gemini, sandboxed chat and bash/sqlite3, MCP approval, model APIs, MCP sign-in, gateway models, gateway MCP, always-on intake, Super Agent, and ordinary task threads)")


if __name__ == "__main__":
    main()
