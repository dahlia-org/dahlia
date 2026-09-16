"""Databricks Apps service-principal authentication for OpenAI-compatible APIs."""

import asyncio
import base64
import json
import os
import threading
import time
from datetime import datetime
from urllib.parse import quote, unquote, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen


class DatabricksOAuthTokenProvider:
    def __init__(self, host, client_id, client_secret, *, opener=urlopen, clock=time.monotonic):
        self.host = host.rstrip("/")
        self.client_id = client_id
        self.client_secret = client_secret
        self.opener = opener
        self.clock = clock
        self.cached = None
        self.expires_at = 0.0
        self.lock = threading.Lock()

    @classmethod
    def from_env(cls, env=os.environ):
        required = ("DATABRICKS_HOST", "DATABRICKS_CLIENT_ID", "DATABRICKS_CLIENT_SECRET")
        missing = [name for name in required if not env.get(name)]
        if missing:
            raise RuntimeError(f"Missing Databricks Apps variables: {', '.join(missing)}")
        host = env["DATABRICKS_HOST"]
        if "://" not in host:
            host = f"https://{host}"
        return cls(host, env["DATABRICKS_CLIENT_ID"], env["DATABRICKS_CLIENT_SECRET"])

    @property
    def ai_gateway_base_url(self):
        return f"{self.host}/ai-gateway/mlflow/v1"

    def resolve_ai_gateway_base_url(self, base_url=None):
        target = base_url or self.ai_gateway_base_url
        workspace = urlsplit(self.host)
        resolved = urlsplit(target)
        if (resolved.scheme, resolved.netloc) != (workspace.scheme, workspace.netloc):
            raise RuntimeError("Databricks AI Gateway URL must use the configured workspace origin")
        return target

    def get_token(self):
        with self.lock:
            if self.cached and self.expires_at > self.clock() + 60:
                return self.cached
            try:
                token, expires_in = self._request_token()
            except RuntimeError:
                if self.cached and self.expires_at > self.clock():
                    return self.cached
                raise
            self.cached = token
            self.expires_at = self.clock() + expires_in
            return self.cached

    async def get_token_async(self):
        return await asyncio.to_thread(self.get_token)

    def _request_token(self):
        credentials = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
        request = Request(
            f"{self.host}/oidc/v1/token",
            data=urlencode({"grant_type": "client_credentials", "scope": "all-apis"}).encode(),
            headers={
                "Authorization": f"Basic {credentials}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        try:
            with self.opener(request, timeout=30) as response:
                body = json.loads(response.read())
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError("Databricks OAuth token request failed") from error
        if not isinstance(body, dict):
            raise RuntimeError("Databricks OAuth token response is invalid")
        token = body.get("access_token")
        expires_in = body.get("expires_in")
        if not isinstance(token, str) or not token or not isinstance(expires_in, (int, float)) or expires_in <= 0:
            raise RuntimeError("Databricks OAuth token response is invalid")
        return token, expires_in


class DatabricksLakebaseCredentialProvider:
    """Refresh short-lived PostgreSQL credentials for a Lakebase endpoint."""

    def __init__(self, auth, endpoint, *, opener=urlopen, clock=time.time):
        self.auth = auth
        self.endpoint = endpoint
        self.opener = opener
        self.clock = clock
        self.cached = None
        self.expires_at = 0.0
        self.lock = threading.Lock()

    @classmethod
    def from_env(cls, env=os.environ):
        endpoint = env.get("LAKEBASE_ENDPOINT")
        if not endpoint:
            raise RuntimeError("Missing Databricks Apps variable: LAKEBASE_ENDPOINT")
        return cls(DatabricksOAuthTokenProvider.from_env(env), endpoint)

    def get_token(self):
        with self.lock:
            if self.cached and self.expires_at > self.clock() + 120:
                return self.cached
            try:
                token, expires_at = self._request_token()
            except RuntimeError:
                if self.cached and self.expires_at > self.clock():
                    return self.cached
                raise
            self.cached = token
            self.expires_at = expires_at
            return token

    def _request_token(self):
        request = Request(
            f"{self.auth.host}/api/2.0/postgres/credentials",
            data=json.dumps({"endpoint": self.endpoint}).encode(),
            headers={
                "Authorization": f"Bearer {self.auth.get_token()}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with self.opener(request, timeout=30) as response:
                body = json.loads(response.read())
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError("Databricks Lakebase credential request failed") from error

        if not isinstance(body, dict):
            raise RuntimeError("Databricks Lakebase credential response is invalid")
        token = body.get("token")
        expire_time = body.get("expire_time")
        if not isinstance(token, str) or not token or not isinstance(expire_time, str):
            raise RuntimeError("Databricks Lakebase credential response is invalid")
        try:
            expires_at = datetime.fromisoformat(expire_time.replace("Z", "+00:00")).timestamp()
        except ValueError as error:
            raise RuntimeError("Databricks Lakebase credential response is invalid") from error
        if expires_at <= self.clock():
            raise RuntimeError("Databricks Lakebase credential response is expired")
        return token, expires_at

    async def get_token_async(self):
        return await asyncio.to_thread(self.get_token)


_lakebase_provider = None
_lakebase_provider_key = None


def lakebase_database_auth_enabled(env=os.environ, database_url=None):
    if not env.get("LAKEBASE_ENDPOINT"):
        return False
    if database_url is None:
        return True
    expected_host = env.get("PGHOST", "").strip("[]").casefold()
    actual_host = urlsplit(database_url).hostname
    return bool(actual_host and actual_host.casefold() == expected_host)


def get_lakebase_credential_provider(env=os.environ):
    global _lakebase_provider, _lakebase_provider_key
    key = tuple(
        env.get(name)
        for name in ("DATABRICKS_HOST", "DATABRICKS_CLIENT_ID", "DATABRICKS_CLIENT_SECRET", "LAKEBASE_ENDPOINT")
    )
    if _lakebase_provider is None or _lakebase_provider_key != key:
        _lakebase_provider = DatabricksLakebaseCredentialProvider.from_env(env)
        _lakebase_provider_key = key
    return _lakebase_provider


def lakebase_database_password():
    return get_lakebase_credential_provider().get_token()


async def lakebase_database_password_async():
    return await get_lakebase_credential_provider().get_token_async()


def refresh_lakebase_database_url(database_url, env=os.environ):
    """Embed a fresh Lakebase credential for synchronous PostgreSQL clients."""
    if "://" not in database_url or not lakebase_database_auth_enabled(env, database_url):
        return database_url

    parsed = urlsplit(database_url)
    if parsed.scheme not in ("postgres", "postgresql", "postgres+asyncpg", "postgresql+asyncpg"):
        return database_url

    password = get_lakebase_credential_provider(env).get_token()
    username = parsed.username or env.get("PGUSER")
    if not username or not parsed.hostname:
        return database_url
    host = parsed.hostname
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    port = f":{parsed.port}" if parsed.port else ""
    netloc = f"{quote(unquote(username), safe='')}:{quote(password, safe='')}@{host}{port}"
    return urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment))
