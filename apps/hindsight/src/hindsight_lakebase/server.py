"""Dahlia's API entrypoint: content-free logging for Hindsight and Uvicorn."""

import os

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

    from hindsight_api.main import main as serve

    serve()


if __name__ == "__main__":
    main()
