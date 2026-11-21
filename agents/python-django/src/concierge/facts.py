"""The facts the Runtime Concierge reports, both over GET /runtime and to the model through the runtime_facts tool.

Everything is read from the live process, so the answer shows what Brewlet actually launched.
"""

import json
import platform
import sys
from collections.abc import Iterator
from importlib import metadata
from pathlib import Path
from types import ModuleType
from typing import Any

import concierge
import copilot
import copilot_django
from django.conf import settings

from concierge.probe import SidecarProbe


class RuntimeFacts:
    def __init__(self, sidecar: SidecarProbe) -> None:
        self._sidecar = sidecar

    async def describe(self) -> dict[str, Any]:
        return {
            "agent": self._agent(),
            "language": self._language(),
            "copilot": await self._copilot(),
            "deployment": self._deployment(),
        }

    async def text(self, topic: str | None) -> str:
        """The facts as flat `key: value` lines, optionally narrowed to one section (an unknown topic means all)."""
        facts = await self.describe()
        wanted = (topic or "all").strip().lower()
        if wanted in facts:
            facts = {wanted: facts[wanted]}
        return "".join(f"{name}: {value if isinstance(value, str) else json.dumps(value)}\n" for name, value in _flatten(facts))

    def _agent(self) -> dict[str, Any]:
        return {
            "name": settings.AGENT_NAME,
            "framework": {"name": "Django", "version": metadata.version("django")},
            "location": _location(concierge),
        }

    def _language(self) -> dict[str, Any]:
        return {
            "name": "python",
            "version": platform.python_version(),
            "vendor": platform.python_implementation(),
            "home": sys.base_prefix,
        }

    async def _copilot(self) -> dict[str, Any]:
        return {
            "sdk": _library("microsoft-copilot-sdk", copilot),
            "integration": _library("copilot-django", copilot_django),
            "cli": await self._sidecar.describe(),
        }

    def _deployment(self) -> dict[str, Any]:
        return {
            "runtimeId": settings.AGENT_RUNTIME_ID,
            "pod": settings.POD_NAME,
            "namespace": settings.POD_NAMESPACE,
            "node": settings.NODE_NAME,
        }


def _library(distribution: str, package: ModuleType) -> dict[str, str]:
    return {"name": distribution, "version": metadata.version(distribution), "location": _location(package)}


def _location(package: ModuleType) -> str:
    return str(Path(package.__file__).parent)


def _flatten(values: dict[str, Any], prefix: str = "") -> Iterator[tuple[str, Any]]:
    for key, value in values.items():
        name = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            yield from _flatten(value, name)
        else:
            yield name, value
