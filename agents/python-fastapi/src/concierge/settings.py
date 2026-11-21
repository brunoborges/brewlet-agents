"""Configuration, read once at startup from the environment that the Pod provides."""

import tempfile
from pathlib import Path

from copilot_fastapi import CopilotSettings
from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Each field is read from the environment variable with the same name in upper case.

    The two Copilot CLI settings have no default on purpose: a Pod without them fails at startup
    instead of answering every request with an error.
    """

    model_config = SettingsConfigDict(extra="ignore")

    port: int = 8080
    copilot_cli_url: str
    copilot_connection_token: SecretStr

    agent_name: str = "python-fastapi"
    agent_runtime_id: str = "unknown"
    pod_name: str = Field("unknown", validation_alias=AliasChoices("pod_name", "hostname"))
    pod_namespace: str = "unknown"
    node_name: str = "unknown"

    response_timeout: float = 120
    probe_timeout: float = 3
    shutdown_timeout: int = 15
    session_max_age: int = 3600
    state_dir: Path = Path(tempfile.gettempdir()) / "concierge"

    def copilot(self) -> CopilotSettings:
        """The integration's settings: attach to the sidecar over TCP, in an empty session mode.

        The integration creates its state directory even when it attaches, so it must be writable.
        """
        return CopilotSettings(
            runtime={
                "connection": "uri",
                "url": self.copilot_cli_url,
                "connection_token": self.copilot_connection_token,
                "mode": "empty",
                "base_directory": self.state_dir,
                "request_timeout": self.response_timeout,
            },
            sessions={"max_age": self.session_max_age},
        )
