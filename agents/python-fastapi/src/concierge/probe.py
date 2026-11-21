"""Talks to the Copilot CLI sidecar through the SDK client that the integration manages."""

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any

from copilot_fastapi import Copilot


class SidecarError(Exception):
    """The sidecar did not answer in time, or could not be reached."""


class SidecarProbe:
    def __init__(self, copilot: Copilot, endpoint: str, timeout: float) -> None:
        self._runtime = copilot.runtime
        self._endpoint = endpoint
        self._timeout = timeout

    async def is_reachable(self) -> bool:
        """True when the sidecar answers a ping; the first call also connects the lazily started client."""
        try:
            await self._call(lambda client: client.ping("readyz"))
        except SidecarError:
            return False
        return True

    async def is_authenticated(self) -> bool:
        return (await self._call(lambda client: client.get_auth_status())).is_authenticated

    async def describe(self) -> dict[str, Any]:
        """Live facts about the sidecar; never raises, so /runtime works even when the sidecar is down."""
        cli: dict[str, Any] = {"endpoint": self._endpoint}
        try:
            status = await self._call(lambda client: client.get_status())
            auth = await self._call(lambda client: client.get_auth_status())
        except SidecarError as error:
            return {**cli, "attached": False, "error": str(error)}
        return {
            **cli,
            "attached": True,
            "version": status.version,
            "protocolVersion": status.protocol_version,
            "authenticated": auth.is_authenticated,
            "authType": auth.auth_type,
        }

    async def _call(self, call: Callable[[Any], Awaitable[Any]]) -> Any:
        async def on_copilot_loop() -> Any:
            client = await self._runtime.client()
            # The runtime caches its client for good; start() reconnects it after a sidecar restart and is a no-op otherwise.
            await client.start()
            return await call(client)

        # The SDK client lives on the integration's own event loop; the runtime_facts tool is already there.
        try:
            if self._runtime.in_loop_thread():
                return await asyncio.wait_for(on_copilot_loop(), self._timeout)
            return await asyncio.wait_for(self._runtime.run_async(on_copilot_loop()), self._timeout)
        except TimeoutError:
            raise SidecarError(f"no answer from the Copilot CLI sidecar within {self._timeout:g}s") from None
        except Exception as error:
            raise SidecarError(f"Copilot CLI sidecar is unreachable: {error or type(error).__name__}") from error
