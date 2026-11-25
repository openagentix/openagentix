"""Tests for the Python sample agent. No network, no paid model: a fake model stands in.

The last class is a contract test against services/stub-model (the scripted model the quick start uses). It builds that
service with `go build` and skips itself when Go is not installed.
"""
import asyncio
import json
import os
import shutil
import socket
import subprocess
import time

import httpx
import pytest
from starlette.testclient import TestClient

import agent

HEADERS = {"A2A-Version": "1.0", "Content-Type": "application/json"}


def rpc(method, params=None, id_=1):
    return {"jsonrpc": "2.0", "id": id_, "method": method, "params": params or {}}


def send(text="hello", message_id="m1"):
    return rpc("SendMessage", {"message": {"messageId": message_id, "role": "ROLE_USER", "parts": [{"text": text}]}})


class FakeModel:
    """Records what it was asked and answers with a fixed text."""

    def __init__(self, answer="four", model="fake-1", error=None):
        self.answer, self.model, self.error, self.asked = answer, model, error, []

    async def complete(self, text):
        self.asked.append(text)
        if self.error:
            raise self.error
        return self.answer, self.model


def client_for(model):
    return TestClient(agent.build_app(model, base_url="http://agent.test:8080"))


def result_text(body):
    parts = body["result"]["message"]["parts"]
    return " ".join(p["text"] for p in parts)


class TestSettings:
    def test_defaults(self):
        s = agent.Settings.from_env({})
        assert s.port == 8080
        assert s.host == "0.0.0.0"
        assert not s.complete

    def test_port_from_env(self):
        assert agent.Settings.from_env({"PORT": "9090"}).port == 9090

    def test_listen_addr_wins_like_the_go_sample(self):
        s = agent.Settings.from_env({"LISTEN_ADDR": ":9191", "PORT": "9090"})
        assert (s.host, s.port) == ("0.0.0.0", 9191)

    def test_bad_port_is_refused(self):
        with pytest.raises(ValueError):
            agent.Settings.from_env({"PORT": "80"})  # below 1024: the platform runs non-root
        with pytest.raises(ValueError):
            agent.Settings.from_env({"PORT": "abc"})

    def test_complete_needs_all_three(self):
        env = {"OPENAI_BASE_URL": "http://m/v1", "OPENAI_API_KEY": "k", "OPENAGENTIX_MODEL": "m"}
        assert agent.Settings.from_env(env).complete
        for name in env:
            partial = {k: v for k, v in env.items() if k != name}
            assert agent.Settings.from_env(partial).missing == [name]


class TestCard:
    def test_card_is_a2a_1_0_jsonrpc(self):
        r = client_for(FakeModel()).get("/.well-known/agent-card.json")
        assert r.status_code == 200
        assert r.headers["content-type"].startswith("application/json")
        card = r.json()
        assert card["name"] == "echo-a2a-python"
        iface = card["supportedInterfaces"][0]
        assert iface["protocolBinding"] == "JSONRPC"
        assert iface["protocolVersion"] == "1.0"
        assert iface["url"] == "http://agent.test:8080/"
        assert card["capabilities"].get("streaming", False) is False
        assert card["skills"] and card["defaultInputModes"] and card["defaultOutputModes"]
        assert len(r.content) < 64 * 1024


class TestSendMessage:
    def test_answers_with_a_message_naming_the_model(self):
        model = FakeModel(answer="four", model="fake-1")
        r = client_for(model).post("/", json=send("what is 2+2?"), headers=HEADERS)
        body = r.json()
        assert body["id"] == 1
        assert result_text(body) == "model fake-1 answered: four"
        assert model.asked == ["what is 2+2?"]

    def test_role_is_agent(self):
        body = client_for(FakeModel()).post("/", json=send(), headers=HEADERS).json()
        assert body["result"]["message"]["role"] == "ROLE_AGENT"

    def test_multiple_text_parts_are_joined(self):
        model = FakeModel()
        req = rpc("SendMessage", {"message": {"messageId": "m", "role": "ROLE_USER", "parts": [{"text": "a"}, {"text": "b"}]}})
        client_for(model).post("/", json=req, headers=HEADERS)
        assert model.asked == ["a\nb"]

    def test_message_without_text_is_an_error_and_never_asks_the_model(self):
        model = FakeModel()
        req = rpc("SendMessage", {"message": {"messageId": "m", "role": "ROLE_USER", "parts": []}})
        body = client_for(model).post("/", json=req, headers=HEADERS).json()
        assert "error" in body
        assert model.asked == []

    def test_model_failure_is_a_short_error_without_detail(self):
        model = FakeModel(error=agent.ModelError("model returned status 500"))
        text = client_for(model).post("/", json=send(), headers=HEADERS).text
        assert "error" in text
        assert "500" not in text

    def test_unexpected_exception_does_not_leak_its_text(self):
        model = FakeModel(error=RuntimeError("secret-key-abc"))
        r = client_for(model).post("/", json=send(), headers=HEADERS)
        assert "secret-key-abc" not in r.text

    def test_unknown_method_is_32601(self):
        body = client_for(FakeModel()).post("/", json=rpc("NoSuchMethod"), headers=HEADERS).json()
        assert body["error"]["code"] == -32601

    def test_streaming_is_refused_not_claimed(self):
        r = client_for(FakeModel()).post("/", json=send() | {"method": "SendStreamingMessage"}, headers=HEADERS)
        assert "error" in r.json()


class TestModelClient:
    """The HTTP call to an OpenAI-compatible endpoint, against a fake transport."""

    def make(self, handler):
        s = agent.Settings.from_env({"OPENAI_BASE_URL": "http://m/v1/", "OPENAI_API_KEY": "sk-test", "OPENAGENTIX_MODEL": "want"})
        return agent.OpenAIChatModel(s, transport=httpx.MockTransport(handler))

    def test_posts_to_chat_completions_with_bearer_key(self):
        seen = {}

        def handler(request):
            seen["url"], seen["auth"], seen["body"] = str(request.url), request.headers["authorization"], json.loads(request.content)
            return httpx.Response(200, json={"model": "got", "choices": [{"message": {"content": "hi"}}]})

        answer, model = asyncio.run(self.make(handler).complete("question"))
        assert (answer, model) == ("hi", "got")
        assert seen["url"] == "http://m/v1/chat/completions"
        assert seen["auth"] == "Bearer sk-test"
        assert seen["body"] == {"model": "want", "messages": [{"role": "user", "content": "question"}]}

    def test_model_name_falls_back_to_the_requested_one(self):
        h = lambda r: httpx.Response(200, json={"choices": [{"message": {"content": "x"}}]})
        assert asyncio.run(self.make(h).complete("q")) == ("x", "want")

    def test_error_status_never_carries_key_or_body(self):
        h = lambda r: httpx.Response(401, text="bad key sk-test")
        with pytest.raises(agent.ModelError) as e:
            asyncio.run(self.make(h).complete("q"))
        assert "sk-test" not in str(e.value)

    def test_unreadable_body(self):
        h = lambda r: httpx.Response(200, text="not json")
        with pytest.raises(agent.ModelError):
            asyncio.run(self.make(h).complete("q"))

    def test_missing_variable_is_named(self):
        m = agent.OpenAIChatModel(agent.Settings.from_env({"OPENAI_BASE_URL": "http://m"}))
        with pytest.raises(agent.ModelError) as e:
            asyncio.run(m.complete("q"))
        assert "OPENAI_API_KEY" in str(e.value)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def stub_model(tmp_path_factory):
    go = shutil.which("go")
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    if not go or not os.path.isdir(os.path.join(repo, "services", "stub-model")):
        pytest.skip("Go or services/stub-model is not available")
    binary = tmp_path_factory.mktemp("stub") / "stub-model"
    subprocess.run([go, "build", "-o", str(binary), "./cmd/stub-model"], cwd=os.path.join(repo, "services", "stub-model"), check=True)
    port = free_port()
    proc = subprocess.Popen([str(binary)], env={**os.environ, "STUB_MODEL_ADDR": f"127.0.0.1:{port}"})
    try:
        for _ in range(50):
            try:
                if httpx.get(f"http://127.0.0.1:{port}/healthz").status_code == 200:
                    break
            except httpx.HTTPError:
                time.sleep(0.1)
        else:
            raise RuntimeError("stub-model did not start")
        yield f"http://127.0.0.1:{port}/v1"
    finally:
        proc.terminate()
        proc.wait(timeout=5)


class TestAgainstStubModel:
    def test_full_path_agent_to_stub_model(self, stub_model):
        s = agent.Settings.from_env({"OPENAI_BASE_URL": stub_model, "OPENAI_API_KEY": "not-a-secret", "OPENAGENTIX_MODEL": "quickstart-model"})
        c = TestClient(agent.build_app(agent.OpenAIChatModel(s), base_url="http://agent.test:8080"))
        body = c.post("/", json=send("Say hello"), headers=HEADERS).json()
        text = result_text(body)
        assert text.startswith("model ")
        assert "answered: [stub model]" in text
