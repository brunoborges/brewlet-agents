"""The HTTP API of the Runtime Concierge: /healthz, /readyz, /runtime and /ask."""

import re
import uuid
from typing import Annotated, Any

from copilot_fastapi import Copilot, CopilotTimeout
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from concierge.agent import ConciergeAgent
from concierge.facts import RuntimeFacts
from concierge.probe import SidecarError, SidecarProbe
from concierge.settings import Settings

MAX_QUESTION_LENGTH = 4000
CONVERSATION_ID = re.compile(r"[A-Za-z0-9._:/-]{1,128}")

settings = Settings()
copilot = Copilot(settings.copilot(), agents=[ConciergeAgent])
sidecar = SidecarProbe(copilot, settings.copilot_cli_url, settings.probe_timeout)
facts = RuntimeFacts(settings, sidecar)


def get_facts() -> RuntimeFacts:
    return facts


# FastAPI builds one ConciergeAgent per request; the runtime_facts tool finds `facts` in its attributes.
Concierge = Annotated[ConciergeAgent, copilot.depends(ConciergeAgent, facts=Depends(get_facts))]

app = FastAPI(
    title="Runtime Concierge",
    lifespan=copilot.lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


class AskRequest(BaseModel):
    question: str | None = None
    conversation_id: str | None = Field(default=None, alias="conversationId")


def error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse({"error": code, "message": message}, status_code=status)


def describe_duration(seconds: float) -> str:
    amount, unit = (int(seconds // 60), "minute") if seconds >= 60 and seconds % 60 == 0 else (seconds, "second")
    return f"{amount:g} {unit}{'' if amount == 1 else 's'}"


@app.exception_handler(RequestValidationError)
async def malformed_request(request: Request, exc: RequestValidationError) -> JSONResponse:
    return error(400, "bad_request", 'the body must be a JSON object like {"question": "...", "conversationId": "..."}')


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "UP"}


@app.get("/readyz")
async def readyz() -> JSONResponse:
    if await sidecar.is_reachable():
        return JSONResponse({"status": "READY"})
    return JSONResponse({"status": "NOT_READY", "reason": "copilot_cli_unreachable"}, status_code=503)


@app.get("/runtime")
async def runtime(facts: Annotated[RuntimeFacts, Depends(get_facts)]) -> dict[str, Any]:
    return await facts.describe()


@app.post("/ask")
async def ask(body: AskRequest, agent: Concierge) -> JSONResponse:
    question = body.question
    if question is None or not question.strip() or len(question) > MAX_QUESTION_LENGTH:
        return error(400, "bad_request", f"question is required and must be at most {MAX_QUESTION_LENGTH} characters")
    conversation_id = str(uuid.uuid4()) if body.conversation_id is None else body.conversation_id
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

    try:
        answer = await agent.aask(question, conversation_id=conversation_id, timeout=settings.response_timeout)
    except CopilotTimeout:
        return error(504, "timeout", f"the model did not answer within {describe_duration(settings.response_timeout)}")
    except Exception as exc:
        return error(502, "agent_error", str(exc))
    return JSONResponse({"answer": answer, "conversationId": conversation_id})
