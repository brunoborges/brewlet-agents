"""The runtime_facts tool; copilot_django imports this module at startup, which registers the tool."""

from typing import Annotated

from copilot_django import ToolContext, copilot_tool
from pydantic import Field


@copilot_tool(
    description=(
        "Verified facts about the environment this agent runs in: the Python runtime (version, home directory),"
        " the application artifact (framework, code location), the Copilot SDK and integration versions, the"
        " Copilot CLI sidecar (version, authentication) and the Kubernetes/Brewlet deployment (runtime image id,"
        " pod). Call it before answering any question about these."
    )
)
async def runtime_facts(
    ctx: ToolContext,
    topic: Annotated[
        str | None, Field(description="Which part to return: all, language, agent, copilot or deployment")
    ] = None,
) -> str:
    return await ctx.agent.attributes["facts"].text(topic)
