#!/usr/bin/env python3
"""Check Dahlia's Pi extension against an installed Pi, a loopback model gateway, and loopback MCPs.

Usage: python3 apps/macos/scripts/test-pi-extension.py [--pi /path/to/pi]  (default: pi on PATH)
Uses an isolated agent directory and synthetic tokens; nothing leaves 127.0.0.1.
"""
import argparse
import base64
import hashlib
import socket
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

ROOT = Path(__file__).resolve().parents[3]
EXTENSION = ROOT / "apps/macos/Sources/Dahlia/PiExtension/dahlia.ts"
# dahlia.ts registers the Unity AI Gateway sign-ins in every process, so chat adds only Pi's MCP extension, as Dahlia does.
CHAT_EXTENSIONS = ["-e", "builtin:mcp"]
CHAT_ARGUMENTS = ["--no-session", *CHAT_EXTENSIONS, "--tools", "read,ls,write,edit,bash,mcp__dahlia__*"]
SANDBOX = EXTENSION.with_name("pi.sb")


def sandbox(root):
    """The command prefix that runs chat's commands and file operations under Dahlia's Seatbelt profile, as `PiSandbox` does."""
    parameters = {"WORK": root / "workspace", "TMP": root / "tmp", "PI_TMP": root / "pi-tmp", "AGENT": root / "agent",
                  "APP_SUPPORT": root / "support", "RELEASED_APP_SUPPORT": root / "released", "PI": root / "pi",
                  "RESOURCES": EXTENSION.parent,
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
                    urllib.request.urlopen(url, timeout=10).read()
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


def run(pi, mode, script, arguments, environment, approval="accept", approval_mode="ask", api="openai-responses", mcp_servers=None,
        compat=None, auth=None):
    """Runs one prompt; returns the gateway requests, tool results, bridge calls, and whether ../outside.txt exists."""
    requests, tool_results, bridge = [], [], []
    server = gateway(script, requests)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary).resolve()
        (root / "agent").mkdir()
        (root / "workspace").mkdir()
        (root / "agent/auth.json").write_text(json.dumps(auth or {"marker": "SECRET_MARKER"}))
        with sqlite3.connect(root / "dahlia.sqlite") as database:
            database.execute("CREATE TABLE debug (value TEXT)")
            database.execute("INSERT INTO debug VALUES ('SQLITE_MARKER')")
        (root / "workspace/inside.txt").write_text("INSIDE_MARKER")
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
                answers = {"token": "synthetic-token", "approvalMode": approval_mode, "reviewModel": "", "approval": approval}
                send({"type": "extension_ui_response", "id": record["id"], "value": json.dumps(answers[method])})
            elif record.get("type") == "tool_execution_end":
                tool_results.append("".join(part.get("text", "") for part in record["result"]["content"]))
            elif record.get("type") == "agent_settled":
                break
        process.stdin.close()
        process.wait(timeout=20)
        server.shutdown()
        outside_written = (root / "outside.txt").exists() or "CHANGED" in (root / "agent/auth.json").read_text()
    return requests, tool_results, bridge, outside_written


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
            result = subprocess.run(
                [pi, "--mode", "rpc", "--no-extensions", "-e", str(EXTENSION), "--no-skills",
                 "--no-context-files", "--no-prompt-templates", "--no-themes", "--no-approve", "--no-session", "--no-tools"],
                input='{"id":"commands","type":"get_commands"}\n', text=True, capture_output=True,
                cwd=root, env=dict(env, DAHLIA_PI_MODE=mode), check=True, timeout=20)
            records = [json.loads(line) for line in result.stdout.splitlines()]
            response = next(record for record in records if record.get("id") == "commands")
            assert response.get("success"), response
            return {command["name"] for command in response["data"]["commands"]}

        for mode in ("chat", "skills"):
            names = commands(mode)
            assert {"skill:learned", "skill:packaged", "package-prompt"} <= names, names
            assert "skill:unrelated" not in names and not marker.exists(), names
        for mode in ("control", "summary"):
            names = commands(mode)
            assert not {"skill:learned", "skill:packaged", "package-prompt"} & names and not marker.exists(), names
        (agent / "settings.json").write_text(json.dumps({"packages": [{"source": str(package), "skills": [], "prompts": []}]}))
        names = commands("chat")
        assert "skill:learned" in names and "skill:packaged" not in names and "package-prompt" not in names, names
        subprocess.run([pi, "remove", str(package), "--no-approve"], cwd=root, env=env,
                       capture_output=True, check=True, timeout=20)
        assert not json.loads((agent / "settings.json").read_text()).get("packages")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pi", default="pi")
    pi = parser.parse_args().pi
    package_resources(pi)

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
            return run(pi, "chat", [*steps, {"text": "done"}], CHAT_ARGUMENTS, environment, **options)

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

    # An expired token is refreshed once with the stored refresh token, which Databricks may keep.
    authorizations.clear()
    expired = {provider: dict(credential, expires=1)}
    _, results, _, _ = gateway_chat({"tool": "mcp__gmail__search_messages"}, auth=expired)
    assert results == ["GATEWAY_OK"] and set(authorizations) == {"Bearer mcp-access-2"}, (results, authorizations)
    assert grants == ["authorization_code", "refresh_token"], grants
    server.shutdown()
    foreign_server.shutdown()
    workspace.shutdown()
    print("Pi extension tests passed (token bridge, strict schema on OpenAI/Claude/Gemini, sandboxed chat and bash/sqlite3, MCP approval, model APIs, MCP sign-in, gateway models, and gateway MCP)")


if __name__ == "__main__":
    main()
