"""Dahlia's API entrypoint: content-free logging for Hindsight and Uvicorn."""

import logging
import os
import sys

# Upstream supports an allowlist; omit message, tenant and exception on every level.
LOG_FIELDS = ["severity", "timestamp", "logger"]


def main():
    os.environ["HINDSIGHT_API_LOG_FORMAT"] = "json"
    os.environ["HINDSIGHT_API_LOG_JSON_FIELDS"] = ",".join(LOG_FIELDS)
    os.environ["HINDSIGHT_API_ACCESS_LOG"] = "false"

    from uvicorn.config import LOGGING_CONFIG

    # Uvicorn otherwise installs its own formatter, bypassing Hindsight's allowlist.
    for name in ("default", "access"):
        LOGGING_CONFIG["formatters"][name] = {
            "()": "hindsight_api.config.JsonFormatter",
            "allowed_fields": LOG_FIELDS,
        }

    from hindsight_api.config import JsonFormatter

    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter(allowed_fields=frozenset(LOG_FIELDS)))
    logging.basicConfig(handlers=[handler], level=logging.INFO, force=True)
    try:
        from hindsight_lakebase.reranker import prepare_reranker

        prepare_reranker()
        from hindsight_api.main import main as serve

        serve()
    except Exception:
        # Startup failures can include provider credentials or response bodies in tracebacks.
        print("Hindsight startup failed", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
