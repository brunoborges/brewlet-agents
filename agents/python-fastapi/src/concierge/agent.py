"""The Runtime Concierge: a system prompt and a single tool, runtime_facts."""

from importlib.resources import files
from typing import Annotated

from copilot_fastapi import AgentContext, CopilotAgent, ToolContext, copilot_tool, policies
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


def no_working_directory(ctx: AgentContext) -> None:
    """The sidecar has its own filesystem, so the agent sends it no path from its own."""


class ConciergeAgent(CopilotAgent):
    instructions = files("concierge").joinpath("prompts/concierge.md").read_text(encoding="utf-8")
    tools = [runtime_facts]
    # An allow-list over every tool source (built-in, MCP and custom): only runtime_facts is callable.
    # Excluding the built-in tools is not enough, the CLI's own GitHub MCP tools and web search stay available.
    available_tools = ["custom:runtime_facts"]
    permissions = policies.allow_registered_tools()
    working_directory = no_working_directory
