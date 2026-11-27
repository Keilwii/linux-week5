#!/usr/bin/env bash
# Runs on server A as user "deploy", started by GitHub Actions after rsync:
#   ssh deploy@A "deploy <git-sha>"   (the forced command in ssh-gate.sh runs this file)
#
# Only touches week 5: /opt/viikko5, the viikko5 nginx snippet and viikko5.service.
# The root part is /usr/local/sbin/viikko5-install, the only thing deploy may run with sudo.
set -euo pipefail

REV="${1:-}"
[[ $REV =~ ^[0-9a-f]{40}$ ]] || { echo "usage: deploy.sh <40-char git sha>" >&2; exit 1; }

APP_DIR=/opt/viikko5/app
VENV=/opt/viikko5/venv
cd "$APP_DIR"

echo "==> python venv and dependencies"
[[ -x $VENV/bin/python ]] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --disable-pip-version-check -r requirements.txt

# read by the app once when it starts, shown at /viikko5/health
printf '%s\n' "$REV" > REVISION

echo "==> schema, nginx snippet, systemd unit, restart (as root via sudo)"
sudo -n /usr/local/sbin/viikko5-install

echo "==> waiting for $REV at http://127.0.0.1/viikko5/health"
for _ in $(seq 1 30); do
    if [[ $(curl -fsS http://127.0.0.1/viikko5/health 2>/dev/null) == "$REV" ]]; then
        echo "OK: $REV is running"
        exit 0
    fi
    sleep 2
done

echo "FAIL: the new version did not start" >&2
systemctl status viikko5 --no-pager >&2 || true
exit 1
