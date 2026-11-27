"""Week 5: chat with a small language model running on this server (Ollama).

Nginx -> Gunicorn (unix socket) -> this Flask app -> Ollama on 127.0.0.1:11434
Messages are stored in MariaDB (database viikko5), see db.py.
"""

import json
import os
import re
import secrets
from pathlib import Path

import requests
from flask import Flask, Response, jsonify, redirect, render_template, request, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

import db

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.2:1b")
SYSTEM_PROMPT = os.environ.get(
    "SYSTEM_PROMPT",
    "You are a helpful assistant on a student's Linux server. Keep answers short.",
)
HISTORY_LIMIT = int(os.environ.get("HISTORY_LIMIT", "10"))
MAX_MESSAGE_LEN = 2000
COOKIE = "chat_session"
SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{20,64}$")


REVISION_FILE = Path(__file__).with_name("REVISION")


def read_revision(path=REVISION_FILE):
    # deploy.sh writes the commit SHA here before the restart. It is read once at
    # startup, so /health shows what this process is running, not what is on disk.
    try:
        return path.read_text(encoding="utf-8").strip() or "dev"
    except OSError:
        return "dev"


REVISION = read_revision()

app = Flask(__name__)
# Nginx strips /viikko5 and sends it in X-Forwarded-Prefix. ProxyFix turns that into
# SCRIPT_NAME so url_for() makes /viikko5/... links. Only Nginx can reach the socket,
# so the headers can be trusted.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_prefix=1)


def current_session():
    sid = request.cookies.get(COOKIE, "")
    return sid if SESSION_RE.match(sid) else None


def set_session_cookie(resp, sid):
    # no max_age = browser session cookie: a new browser session gets a new conversation
    resp.set_cookie(
        COOKIE, sid, httponly=True, samesite="Lax", path=(request.script_root or "") + "/"
    )
    return resp


@app.get("/")
def index():
    sid = current_session()
    new_session = sid is None
    if new_session:
        sid = secrets.token_urlsafe(24)
    history, db_error = [], None
    if not new_session:
        try:
            history = db.get_history(sid, limit=100)
        except db.DatabaseError as exc:
            app.logger.error("database error: %s", exc)
            db_error = "Could not load the conversation from the database."
    resp = app.make_response(
        render_template(
            "index.html",
            history=history,
            model=OLLAMA_MODEL,
            db_error=db_error,
            revision=REVISION,
        )
    )
    if new_session:
        set_session_cookie(resp, sid)
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.post("/new")
def new_conversation():
    resp = redirect(url_for("index"))
    return set_session_cookie(resp, secrets.token_urlsafe(24))


@app.get("/docs")
def docs():
    return render_template("docs.html", model=OLLAMA_MODEL, revision=REVISION)


@app.get("/health")
def health():
    return Response(REVISION + "\n", mimetype="text/plain")


def ndjson(obj):
    return json.dumps(obj, ensure_ascii=False) + "\n"


@app.post("/api/chat")
def chat():
    sid = current_session()
    if sid is None:
        return jsonify(error="No session cookie, reload the page."), 400
    data = request.get_json(silent=True) or {}
    message = str(data.get("message", "")).strip()
    if not message:
        return jsonify(error="Empty message."), 400
    if len(message) > MAX_MESSAGE_LEN:
        return jsonify(error=f"Message is too long (max {MAX_MESSAGE_LEN} characters)."), 400

    try:
        past = db.get_history(sid, limit=HISTORY_LIMIT)
        db.save_message(sid, "user", message)
    except db.DatabaseError as exc:
        app.logger.error("database error: %s", exc)
        return jsonify(error="Database error, the message was not saved."), 503

    messages = (
        [{"role": "system", "content": SYSTEM_PROMPT}]
        + [{"role": m["role"], "content": m["content"]} for m in past]
        + [{"role": "user", "content": message}]
    )

    def generate():
        parts = []
        try:
            with requests.post(
                f"{OLLAMA_URL}/api/chat",
                json={"model": OLLAMA_MODEL, "messages": messages, "stream": True},
                stream=True,
                timeout=(5, 300),
            ) as resp:
                resp.raise_for_status()
                for line in resp.iter_lines():
                    if not line:
                        continue
                    chunk = json.loads(line)
                    token = chunk.get("message", {}).get("content", "")
                    if token:
                        parts.append(token)
                        yield ndjson({"token": token})
                    if chunk.get("done"):
                        break
        except (requests.RequestException, ValueError) as exc:
            app.logger.error("ollama request failed: %s", exc)
            yield ndjson({"error": "The model did not answer. Try again in a moment."})
            return

        reply = "".join(parts)
        if reply:
            try:
                db.save_message(sid, "assistant", reply)
            except db.DatabaseError as exc:
                app.logger.error("could not save the reply: %s", exc)
        yield ndjson({"done": True})

    return Response(
        generate(),
        mimetype="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
