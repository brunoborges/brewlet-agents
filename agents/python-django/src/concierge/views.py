"""The HTTP API of the Runtime Concierge: /healthz, /readyz, /runtime and /ask."""

import json
import re
import uuid

from copilot_django import CopilotTimeout
from django.conf import settings
from django.http import HttpRequest, JsonResponse
from django.views.decorators.http import require_GET, require_POST

from concierge.copilot_agents import ConciergeAgent
from concierge.facts import RuntimeFacts
from concierge.probe import SidecarError, SidecarProbe

MAX_QUESTION_LENGTH = 4000
CONVERSATION_ID = re.compile(r"[A-Za-z0-9._:/-]{1,128}")

sidecar = SidecarProbe(settings.COPILOT_CLI_URL, settings.PROBE_TIMEOUT)
facts = RuntimeFacts(sidecar)


def error(status: int, code: str, message: str) -> JsonResponse:
    return JsonResponse({"error": code, "message": message}, status=status)


def describe_duration(seconds: float) -> str:
    amount, unit = (int(seconds // 60), "minute") if seconds >= 60 and seconds % 60 == 0 else (seconds, "second")
    return f"{amount:g} {unit}{'' if amount == 1 else 's'}"


def parse_ask(request: HttpRequest) -> tuple[str | None, str | None] | None:
    """The question and the conversation id of a request body, or None when it is not a JSON object like that."""
    try:
        body = json.loads(request.body)
    except ValueError:
        return None
    if not isinstance(body, dict):
        return None
    question, conversation_id = body.get("question"), body.get("conversationId")
    if any(value is not None and not isinstance(value, str) for value in (question, conversation_id)):
        return None
    return question, conversation_id


@require_GET
async def healthz(request: HttpRequest) -> JsonResponse:
    return JsonResponse({"status": "UP"})


@require_GET
async def readyz(request: HttpRequest) -> JsonResponse:
    if await sidecar.is_reachable():
        return JsonResponse({"status": "READY"})
    return JsonResponse({"status": "NOT_READY", "reason": "copilot_cli_unreachable"}, status=503)


@require_GET
async def runtime(request: HttpRequest) -> JsonResponse:
    return JsonResponse(await facts.describe())


@require_POST
async def ask(request: HttpRequest) -> JsonResponse:
    parsed = parse_ask(request)
    if parsed is None:
        return error(400, "bad_request", 'the body must be a JSON object like {"question": "...", "conversationId": "..."}')
    question, conversation_id = parsed
    if question is None or not question.strip() or len(question) > MAX_QUESTION_LENGTH:
        return error(400, "bad_request", f"question is required and must be at most {MAX_QUESTION_LENGTH} characters")
    if conversation_id is None:
        conversation_id = str(uuid.uuid4())
    if not CONVERSATION_ID.fullmatch(conversation_id):
        return error(400, "bad_request", "conversationId must match [A-Za-z0-9._:/-]{1,128}")

    try:
        authenticated = await sidecar.is_authenticated()
    except SidecarError as exc:
        return error(503, "copilot_unavailable", str(exc))
    if not authenticated:
        return error(
            503,
            "copilot_not_authenticated",
            "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md",
        )

    # The runtime_facts tool finds `facts` in the invocation's attributes.
    agent = ConciergeAgent(user=None, request=None)
    try:
        answer = await agent.aask(
            question,
            conversation_id=conversation_id,
            attributes={"facts": facts},
            timeout=settings.RESPONSE_TIMEOUT,
        )
    except CopilotTimeout:
        return error(504, "timeout", f"the model did not answer within {describe_duration(settings.RESPONSE_TIMEOUT)}")
    except Exception as exc:
        return error(502, "agent_error", str(exc))
    return JsonResponse({"answer": answer, "conversationId": conversation_id})


# Django's own error pages are HTML; an API answers in JSON, whatever fails.
def bad_request(request: HttpRequest, exception: Exception) -> JsonResponse:
    return error(400, "bad_request", "the request was rejected")


def not_found(request: HttpRequest, exception: Exception) -> JsonResponse:
    return error(404, "not_found", "no such endpoint")


def server_error(request: HttpRequest) -> JsonResponse:
    return error(500, "server_error", "unexpected error; see the agent log")
