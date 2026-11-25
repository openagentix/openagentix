"""echo-a2a-python: a sample "bring your own" A2A 1.0 agent built with the official A2A Python SDK (a2a-sdk).

It sends the user's text to an OpenAI-compatible model and answers "model <name> answered: <reply>".
A sample, not production code. It does not stream, keeps no state and writes no files.

The platform sets OPENAI_BASE_URL, OPENAI_API_KEY and OPENAGENTIX_MODEL (ADR 0015). The port comes from PORT
(or LISTEN_ADDR like the Go sample), default 8080.
"""
import logging
import os
import sys

import httpx
import uvicorn
from a2a.helpers.proto_helpers import new_text_message
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandlerV2
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill
from a2a.utils.errors import InternalError, InvalidParamsError, UnsupportedOperationError
from starlette.applications import Starlette

NAME = "echo-a2a-python"
MODEL_TIMEOUT = 30.0
MAX_MODEL_BODY = 4 << 20
REQUIRED_ENV = ("OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAGENTIX_MODEL")

log = logging.getLogger(NAME)


class ModelError(Exception):
    """A model call failed. The text is safe to log: it never holds the key or the upstream body."""


class Settings:
    def __init__(self, host, port, env):
        self.host, self.port, self._env = host, port, env

    @classmethod
    def from_env(cls, env):
        host, port = "0.0.0.0", env.get("PORT", "8080")
        listen = env.get("LISTEN_ADDR")
        if listen:
            h, _, port = listen.rpartition(":")
            host = h or host
        try:
            port = int(port)
        except ValueError:
            raise ValueError("the port is not a number") from None
        if not 1024 <= port <= 65535:
            raise ValueError("the port must be between 1024 and 65535 (the agent runs as a non-root user)")
        return cls(host, port, dict(env))

    def get(self, name):
        return self._env.get(name, "")

    @property
    def missing(self):
        return [n for n in REQUIRED_ENV if not self.get(n)]

    @property
    def complete(self):
        return not self.missing


class OpenAIChatModel:
    """Calls POST {OPENAI_BASE_URL}/chat/completions with the platform's key."""

    def __init__(self, settings, transport=None):
        self.settings = settings
        self.transport = transport

    async def complete(self, text):
        s = self.settings
        if s.missing:
            raise ModelError("missing environment variable " + s.missing[0])
        want = s.get("OPENAGENTIX_MODEL")
        url = s.get("OPENAI_BASE_URL").rstrip("/") + "/chat/completions"
        try:
            async with httpx.AsyncClient(transport=self.transport, timeout=MODEL_TIMEOUT) as client:
                resp = await client.post(
                    url,
                    json={"model": want, "messages": [{"role": "user", "content": text}]},
                    headers={"Authorization": "Bearer " + s.get("OPENAI_API_KEY")},
                )
        except httpx.HTTPError:
            raise ModelError("model request failed") from None
        if resp.status_code != 200:
            raise ModelError(f"model returned status {resp.status_code}")
        if len(resp.content) > MAX_MODEL_BODY:
            raise ModelError("unreadable model response")
        try:
            out = resp.json()
            return out["choices"][0]["message"]["content"], out.get("model") or want
        except (ValueError, KeyError, IndexError, TypeError):
            raise ModelError("unreadable model response") from None


class EchoExecutor(AgentExecutor):
    def __init__(self, model):
        self.model = model

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        text = context.get_user_input()
        if not text:
            raise InvalidParamsError(message="message needs a text part")
        try:
            answer, model = await self.model.complete(text)
        except ModelError as e:
            log.error("model call failed: %s", e)
            raise InternalError(message="model call failed") from None
        except Exception:
            # The SDK would send the exception text to the caller. Log the type only, answer with a fixed sentence.
            log.error("model call failed with an unexpected error", exc_info=False)
            raise InternalError(message="model call failed") from None
        await event_queue.enqueue_event(new_text_message(f"model {model} answered: {answer}"))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise UnsupportedOperationError(message="cancel is not supported")


def build_card(base_url):
    return AgentCard(
        name=NAME,
        description="Sample Python agent: sends your text to the configured model and returns its answer.",
        version="0.1.0",
        supported_interfaces=[AgentInterface(url=base_url.rstrip("/") + "/", protocol_binding="JSONRPC", protocol_version="1.0")],
        capabilities=AgentCapabilities(streaming=False),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[
            AgentSkill(
                id="echo",
                name="Ask the model",
                description="Forwards a text message to the model and reports which model answered.",
                tags=["sample", "echo"],
            )
        ],
    )


def build_app(model, base_url="http://localhost:8080"):
    card = build_card(base_url)
    handler = DefaultRequestHandlerV2(agent_executor=EchoExecutor(model), task_store=InMemoryTaskStore(), agent_card=card)

    async def card_for_request(c):
        return c

    routes = create_agent_card_routes(card, card_modifier=card_for_request) + create_jsonrpc_routes(handler, rpc_url="/")
    return Starlette(routes=routes)


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(name)s %(levelname)s %(message)s")
    settings = Settings.from_env(os.environ)
    if settings.missing:
        log.warning("starting without %s: SendMessage will fail until they are set", ", ".join(settings.missing))
    # The card's URL is only a hint: the platform gate rewrites it to its own address.
    app = build_app(OpenAIChatModel(settings), base_url=f"http://localhost:{settings.port}")
    uvicorn.run(app, host=settings.host, port=settings.port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
