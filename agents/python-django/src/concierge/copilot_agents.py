"""The Runtime Concierge: a system prompt and a single tool, runtime_facts.

copilot_django imports this module at startup, which registers the agent.
"""

from importlib.resources import files

from copilot_django import AgentContext, CopilotAgent, policies

from concierge.copilot_tools import runtime_facts


def no_working_directory(ctx: AgentContext) -> None:
    """The sidecar has its own filesystem, so the agent sends it no path from its own."""


class ConciergeAgent(CopilotAgent):
    name = "concierge"
    instructions = files("concierge").joinpath("prompts/concierge.md").read_text(encoding="utf-8")
    tools = [runtime_facts]
    # An allow-list over every tool source (built-in, MCP and custom): only runtime_facts is callable.
    # Excluding the built-in tools is not enough, the CLI's own GitHub MCP tools and web search stay available.
    available_tools = ["custom:runtime_facts"]
    permissions = policies.allow_registered_tools()
    working_directory = no_working_directory
