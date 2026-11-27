# linux-week5: LLM chat with CI/CD

Linux course, week 5. A web chat where you talk to a small language model (`llama3.2:1b`)
that runs with Ollama on my own Hetzner server (server A, dev-kalle). Messages are saved
in MariaDB. Every push is linted and tested by GitHub Actions, and a push to `main` that
passes is deployed to the server automatically.

- Chat: http://46.62.229.94/viikko5/
- Documentation and test results: http://46.62.229.94/viikko5/docs
- Running version: http://46.62.229.94/viikko5/health (commit SHA)

## Request path

```
browser --80--> nginx (existing week-1 site + include snippets/viikko5.conf)
                  |-- /viikko5/static/  files from /opt/viikko5/app/static
                  '-- /viikko5/        unix socket /run/viikko5/gunicorn.sock
                                          '-> gunicorn + Flask (user viikko5)
                                                |-> Ollama 127.0.0.1:11434 (llama3.2:1b)
                                                '-> MariaDB, database viikko5

GitHub Actions --ssh 22--> deploy@A (forced command: rsync or "deploy <sha>" only)
```

## Files

| Path | What |
|------|------|
| `app.py`, `db.py` | Flask app: `/`, `/api/chat` (streams NDJSON), `/new`, `/docs`, `/health` |
| `templates/`, `static/` | chat page, documentation page, JS and CSS |
| `tests/test_app.py` | pytest, Ollama and MariaDB replaced with fakes |
| `deploy/nginx/viikko5.conf` | nginx snippet, only `location` blocks |
| `deploy/systemd/viikko5.service` | gunicorn as user `viikko5` |
| `deploy/sql/schema.sql` | `messages` table |
| `scripts/server-setup.sh` | one-time setup on the server (run with sudo) |
| `scripts/deploy.sh` | run on the server by GitHub Actions as user `deploy` |
| `scripts/viikko5-install.sh` | root part of the deploy, installed as `/usr/local/sbin/viikko5-install` |
| `scripts/ssh-gate.sh` | forced command for the GitHub Actions key |
| `.github/workflows/ci-cd.yml` | the pipeline |

## Pipeline

- **Every push and pull request:** `ruff check .`, `pytest`, `bash -n scripts/*.sh`.
- **Push to main, only if the tests passed:** rsync the code to `/opt/viikko5/app`,
  `ssh deploy@A "deploy <sha>"` which installs the requirements into the venv, writes the SHA
  to `REVISION`, and runs `sudo viikko5-install` (schema, nginx snippet with `nginx -t`,
  systemd unit, restart of `viikko5` only, nginx reload). Then it waits until
  `/viikko5/health` returns the new SHA, and the workflow checks the public URLs again,
  earlier weeks included. Any failure makes the run red.

## Setup on a server

1. Make a key pair for GitHub Actions (not your own key):
   `ssh-keygen -t ed25519 -f viikko5-deploy -N "" -C github-actions-viikko5`
2. Copy `viikko5-deploy.pub` to `~/viikko5-deploy.pub` on the server, clone this repo there and run
   `sudo bash ~/linux-week5/scripts/server-setup.sh`. It checks memory/disk/ports, installs
   Ollama and the model, creates the users, the database, `/etc/viikko5/viikko5.env` and adds
   one `include snippets/viikko5.conf;` line to the existing nginx site.
3. Repository secrets: `SSH_PRIVATE_KEY` (the private key) and `SSH_KNOWN_HOSTS`
   (`ssh-keygen -F <server-ip>` from a machine that has already connected). Delete the local
   private key after that.
4. Push to main.

## Local development

```
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
ruff check . && pytest
```

Secrets (database passwords, private key) are never in this repo. They live in
`/etc/viikko5/` on the server and in GitHub Actions secrets.
