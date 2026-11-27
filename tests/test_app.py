"""Tests run without Ollama and without MariaDB: both are replaced with fakes."""

import json

import pytest
import requests

import app as app_module
import db


class FakeDB:
    def __init__(self):
        self.rows = {}
        self.fail = False

    def save_message(self, session_id, role, content):
        if self.fail:
            raise db.DatabaseError(2002, "can't connect")
        self.rows.setdefault(session_id, []).append({"role": role, "content": content})

    def get_history(self, session_id, limit=10):
        if self.fail:
            raise db.DatabaseError(2002, "can't connect")
        return list(self.rows.get(session_id, []))[-limit:]


class FakeOllama:
    def __init__(self, lines):
        self.lines = [json.dumps(line).encode() for line in lines]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        pass

    def iter_lines(self):
        yield from self.lines


SID = "test-session-abcdefghijklmnop"


@pytest.fixture
def fake_db(monkeypatch):
    fake = FakeDB()
    monkeypatch.setattr(db, "save_message", fake.save_message)
    monkeypatch.setattr(db, "get_history", fake.get_history)
    return fake


@pytest.fixture
def client(fake_db):
    app_module.app.config["TESTING"] = True
    c = app_module.app.test_client()
    c.set_cookie(app_module.COOKIE, SID)
    return c


def fake_ollama(monkeypatch, lines, captured=None):
    def fake_post(url, **kwargs):
        if captured is not None:
            captured["url"] = url
            captured.update(kwargs)
        return FakeOllama(lines)

    monkeypatch.setattr(app_module.requests, "post", fake_post)


def events(resp):
    return [json.loads(x) for x in resp.get_data(as_text=True).splitlines() if x.strip()]


def test_index_shows_chat(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b'id="chat-form"' in resp.data


def test_links_use_forwarded_prefix(client):
    resp = client.get("/", headers={"X-Forwarded-Prefix": "/viikko5"})
    assert b'href="/viikko5/static/style.css' in resp.data
    assert b'src="/viikko5/static/chat.js' in resp.data
    assert b'data-base="/viikko5"' in resp.data


def test_new_visitor_gets_cookie_and_empty_chat(fake_db):
    c = app_module.app.test_client()
    resp = c.get("/", headers={"X-Forwarded-Prefix": "/viikko5"})
    cookie = resp.headers["Set-Cookie"]
    assert cookie.startswith(app_module.COOKIE + "=")
    assert "HttpOnly" in cookie
    assert "Path=/viikko5/" in cookie
    assert "Max-Age" not in cookie  # ends with the browser session
    assert b'class="msg ' not in resp.data


def test_reload_shows_saved_history(client, fake_db):
    fake_db.save_message(SID, "user", "hello there")
    fake_db.save_message(SID, "assistant", "hi!")
    resp = client.get("/")
    assert b"hello there" in resp.data
    assert b"hi!" in resp.data


def test_sessions_are_separate(client, fake_db):
    fake_db.save_message("someone-else-1234567890", "user", "secret plans")
    resp = client.get("/")
    assert b"secret plans" not in resp.data


def test_history_is_escaped(client, fake_db):
    fake_db.save_message(SID, "user", "<script>alert(1)</script>")
    resp = client.get("/")
    assert b"<script>alert(1)" not in resp.data


def test_new_conversation_changes_cookie(client):
    resp = client.post("/new")
    assert resp.status_code == 302
    assert SID not in resp.headers["Set-Cookie"]


def test_read_revision(tmp_path):
    rev = tmp_path / "REVISION"
    assert app_module.read_revision(rev) == "dev"
    rev.write_text("abc123\n")
    assert app_module.read_revision(rev) == "abc123"


def test_health_returns_revision(client, monkeypatch):
    monkeypatch.setattr(app_module, "REVISION", "abc123")
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_data(as_text=True) == "abc123\n"


def test_docs_page(client):
    resp = client.get("/docs")
    assert resp.status_code == 200
    assert b"github.com/Keilwii/linux-week5" in resp.data


def test_chat_needs_cookie(fake_db):
    c = app_module.app.test_client()
    resp = c.post("/api/chat", json={"message": "hi"})
    assert resp.status_code == 400


def test_chat_rejects_empty_message(client):
    assert client.post("/api/chat", json={"message": "  "}).status_code == 400


def test_chat_rejects_long_message(client):
    resp = client.post("/api/chat", json={"message": "x" * (app_module.MAX_MESSAGE_LEN + 1)})
    assert resp.status_code == 400


def test_chat_streams_reply_and_saves_it(client, fake_db, monkeypatch):
    captured = {}
    fake_ollama(
        monkeypatch,
        [
            {"message": {"content": "Hel"}, "done": False},
            {"message": {"content": "lo"}, "done": True},
        ],
        captured,
    )
    resp = client.post("/api/chat", json={"message": "Hi"})
    ev = events(resp)
    assert resp.status_code == 200
    assert "".join(e.get("token", "") for e in ev) == "Hello"
    assert ev[-1] == {"done": True}
    assert captured["url"].endswith("/api/chat")
    assert captured["json"]["messages"][0]["role"] == "system"
    assert captured["json"]["messages"][-1] == {"role": "user", "content": "Hi"}
    assert fake_db.get_history(SID) == [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello"},
    ]


def test_chat_sends_earlier_messages_to_model(client, fake_db, monkeypatch):
    fake_db.save_message(SID, "user", "My name is Kalle")
    fake_db.save_message(SID, "assistant", "Hi Kalle!")
    captured = {}
    fake_ollama(monkeypatch, [{"message": {"content": "Kalle"}, "done": True}], captured)
    client.post("/api/chat", json={"message": "What is my name?"})
    roles = [m["role"] for m in captured["json"]["messages"]]
    assert roles == ["system", "user", "assistant", "user"]


def test_chat_when_ollama_is_down(client, fake_db, monkeypatch):
    def broken(url, **kwargs):
        raise requests.ConnectionError("connection refused")

    monkeypatch.setattr(app_module.requests, "post", broken)
    ev = events(client.post("/api/chat", json={"message": "Hi"}))
    assert "error" in ev[-1]
    assert fake_db.get_history(SID) == [{"role": "user", "content": "Hi"}]


def test_chat_database_down_returns_503(client, fake_db):
    fake_db.fail = True
    resp = client.post("/api/chat", json={"message": "Hi"})
    assert resp.status_code == 503
    assert "error" in resp.get_json()
