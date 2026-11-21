"""Django settings of the Runtime Concierge.

An API-only ASGI project: no database, no sessions, no static files, no templates and no middleware.
Everything that varies between deployments is read from the environment that the Pod provides.
"""

import os
import secrets
import tempfile
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured


def required(name: str) -> str:
    """An environment variable without a default on purpose: a Pod that lacks it fails at startup."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise ImproperlyConfigured(f"the environment variable {name} is required")
    return value


DEBUG = False

# The API is stateless (no sessions, cookies, CSRF forms or signed values), so nothing depends on the secret
# key. The Pod supplies none: use DJANGO_SECRET_KEY when it is set, otherwise generate one for this process.
SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY") or secrets.token_urlsafe(50)

# Requests carry the Pod IP (kubelet probes) or the Service name (clients) as their Host, and neither is known at
# build time, so every host is accepted. That is fine for an internal demo; set DJANGO_ALLOWED_HOSTS (comma
# separated) to narrow it when the agent is reachable from anywhere else.
ALLOWED_HOSTS = [host.strip() for host in os.environ.get("DJANGO_ALLOWED_HOSTS", "*").split(",") if host.strip()]

INSTALLED_APPS = ["copilot_django", "concierge"]
MIDDLEWARE: list[str] = []
ROOT_URLCONF = "concierge.urls"
DATABASES: dict = {}
USE_I18N = False
USE_TZ = True

# With DEBUG off Django logs request errors to a mail handler only, so send them to stderr too.
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "root": {"handlers": ["console"], "level": os.environ.get("LOG_LEVEL", "INFO")},
}

PORT = int(os.environ.get("PORT", "8080"))
AGENT_NAME = os.environ.get("AGENT_NAME", "python-django")
AGENT_RUNTIME_ID = os.environ.get("AGENT_RUNTIME_ID", "unknown")
POD_NAME = os.environ.get("POD_NAME") or os.environ.get("HOSTNAME") or "unknown"
POD_NAMESPACE = os.environ.get("POD_NAMESPACE", "unknown")
NODE_NAME = os.environ.get("NODE_NAME", "unknown")

# The Copilot CLI runs in the sidecar container of the same Pod. Both values come from the Pod spec and have no
# defaults, so a misconfigured Pod fails at startup instead of answering every request with an error.
COPILOT_CLI_URL = required("COPILOT_CLI_URL")
COPILOT_CONNECTION_TOKEN = required("COPILOT_CONNECTION_TOKEN")

RESPONSE_TIMEOUT = float(os.environ.get("RESPONSE_TIMEOUT", "120"))
PROBE_TIMEOUT = float(os.environ.get("PROBE_TIMEOUT", "3"))
SHUTDOWN_TIMEOUT = int(os.environ.get("SHUTDOWN_TIMEOUT", "15"))
SESSION_MAX_AGE = int(os.environ.get("SESSION_MAX_AGE", "3600"))
# The integration creates its state directory even when it only attaches to a sidecar, and the root filesystem
# of the Pod is read-only, so it lives under the temporary directory.
STATE_DIR = Path(os.environ.get("STATE_DIR") or Path(tempfile.gettempdir()) / "concierge")

# Attach to the sidecar over TCP, in an empty session mode (the agent's tools are the only ones it gets).
COPILOT = {
    "RUNTIME": {
        "CONNECTION": "uri",
        "URL": COPILOT_CLI_URL,
        "CONNECTION_TOKEN": COPILOT_CONNECTION_TOKEN,
        "MODE": "empty",
        "BASE_DIRECTORY": STATE_DIR,
        "REQUEST_TIMEOUT": RESPONSE_TIMEOUT,
    },
    "SESSIONS": {"MAX_AGE": SESSION_MAX_AGE},
}
