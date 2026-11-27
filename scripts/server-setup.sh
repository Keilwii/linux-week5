#!/usr/bin/env bash
# One-time setup of week 5 on server A (dev-kalle, Ubuntu 26.04).
# Earlier weeks (week-1 site, /viikko2/, /viikko3/, backups, replication to B) are left alone.
#
# Needs the public half of the GitHub Actions key at ~kalle/viikko5-deploy.pub.
# Run from a clone of the repo:  sudo bash ~/linux-week5/scripts/server-setup.sh
# Safe to run again (keeps the existing passwords).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

MODEL="${MODEL:-llama3.2:1b}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_PUB=/home/kalle/viikko5-deploy.pub
SITE=/etc/nginx/sites-available/week-1
SNIPPET=/etc/nginx/snippets/viikko5.conf
ENV_FILE=/etc/viikko5/viikko5.env
SCHEMA_CNF=/etc/viikko5/schema.cnf

[[ -s $DEPLOY_PUB ]] || { echo "missing $DEPLOY_PUB"; exit 1; }

echo "== resources and ports in use before starting"
free -h
df -h /
ss -ltnp

echo "== packages"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-venv rsync curl

echo "== MariaDB must be writable (this is A, not the read-only replica B)"
[[ $(mariadb -N -e 'SELECT @@global.read_only') == 0 ]] || { echo "read_only is ON, wrong server"; exit 1; }

echo "== linux users"
id viikko5 &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin viikko5
id deploy &>/dev/null || useradd --create-home --shell /bin/bash --comment "GitHub Actions deploys" deploy
passwd -l deploy >/dev/null
# nginx must be able to open the gunicorn socket (group viikko5)
usermod -aG viikko5 www-data

echo "== directories"
install -d -m 755 -o root -g root /opt/viikko5
install -d -m 755 -o deploy -g deploy /opt/viikko5/app /opt/viikko5/venv
install -d -m 750 -o root -g viikko5 /etc/viikko5

gen_pass() { openssl rand -hex 24; }

echo "== database viikko5 and its users (not written to the binlog, see README)"
if [[ ! -f $ENV_FILE ]]; then
    APP_PASS=$(gen_pass)
    SCHEMA_PASS=$(gen_pass)
    mariadb <<SQL
SET SESSION sql_log_bin = 0;
CREATE DATABASE IF NOT EXISTS viikko5 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE OR REPLACE USER 'viikko5'@'localhost' IDENTIFIED BY '$APP_PASS';
GRANT SELECT, INSERT ON viikko5.* TO 'viikko5'@'localhost';
CREATE OR REPLACE USER 'viikko5_schema'@'localhost' IDENTIFIED BY '$SCHEMA_PASS';
GRANT SELECT, CREATE, ALTER, INDEX ON viikko5.* TO 'viikko5_schema'@'localhost';
SQL
    ( umask 027
      cat > "$ENV_FILE" <<ENV
# week 5 chat settings, read by viikko5.service (root:viikko5 640)
DB_SOCKET=/run/mysqld/mysqld.sock
DB_NAME=viikko5
DB_USER=viikko5
DB_PASSWORD=$APP_PASS
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_MODEL=$MODEL
HISTORY_LIMIT=10
ENV
    )
    chown root:viikko5 "$ENV_FILE"
    chmod 640 "$ENV_FILE"
    ( umask 077
      printf '[client]\nuser = viikko5_schema\npassword = %s\nsocket = /run/mysqld/mysqld.sock\n' \
          "$SCHEMA_PASS" > "$SCHEMA_CNF"
    )
    chown root:root "$SCHEMA_CNF"
    chmod 600 "$SCHEMA_CNF"
else
    echo "$ENV_FILE exists, passwords not changed"
fi

echo "== ollama (listens on 127.0.0.1:11434 only)"
if ! command -v ollama &>/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
install -d /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/viikko5.conf <<'EOF'
[Service]
# keep it on localhost (this is also the default) and keep the model in memory
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=OLLAMA_KEEP_ALIVE=24h
EOF
systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 1; done
ollama pull "$MODEL"

echo "== deploy user: key for GitHub Actions, only rsync + deploy allowed"
install -m 755 -o root -g root "$REPO/scripts/ssh-gate.sh" /usr/local/sbin/viikko5-ssh-gate
install -m 755 -o root -g root "$REPO/scripts/viikko5-install.sh" /usr/local/sbin/viikko5-install
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
printf 'restrict,command="/usr/local/sbin/viikko5-ssh-gate" %s\n' "$(cat "$DEPLOY_PUB")" \
    > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
[[ -x /usr/bin/rrsync ]] || { echo "/usr/bin/rrsync missing"; exit 1; }

echo 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/viikko5-install ""' > /etc/sudoers.d/viikko5-deploy.tmp
chmod 440 /etc/sudoers.d/viikko5-deploy.tmp
visudo -cf /etc/sudoers.d/viikko5-deploy.tmp
mv /etc/sudoers.d/viikko5-deploy.tmp /etc/sudoers.d/viikko5-deploy

echo "== nginx: placeholder snippet and one include line in the existing site"
[[ -f $SNIPPET ]] || echo "# week 5 chat, the deploy writes the content" > "$SNIPPET"
if ! grep -qE '^\s*include\s+snippets/viikko5\.conf\s*;' "$SITE"; then
    cp -p "$SITE" /root/week-1.before-viikko5
    sed -i '/include snippets\/viikko2\.conf;/a\	include snippets/viikko5.conf;' "$SITE"
    grep -q 'snippets/viikko5.conf' "$SITE" || { echo "could not add the include line"; exit 1; }
fi
if ! nginx -t; then
    echo "nginx -t failed, restoring the site file"
    [[ -f /root/week-1.before-viikko5 ]] && cp -p /root/week-1.before-viikko5 "$SITE"
    exit 1
fi
# restart (not reload) so www-data's new group is used
systemctl restart nginx

echo "== done"
ollama list
grep -n 'include' "$SITE"
echo "Next: push to main, GitHub Actions does the first deploy."
