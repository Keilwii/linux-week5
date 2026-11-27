#!/usr/bin/env bash
# Collects the evidence for the week 5 page into ~kalle/viikko5-evidence.txt.
# Passwords are never printed, and the password hashes in SHOW GRANTS are replaced.
#   sudo bash ~/linux-week5/scripts/evidence.sh
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
OUT=/home/kalle/viikko5-evidence.txt

run() { echo; echo "\$ $*"; "$@" 2>&1; }
{
    echo "collected $(date -u '+%Y-%m-%d %H:%M:%S UTC') on $(hostname)"
    run systemctl status viikko5 --no-pager -n 5
    run systemctl show viikko5 -p User -p Group
    run ls -ld /opt/viikko5 /opt/viikko5/app /opt/viikko5/venv
    run ls -l /opt/viikko5/app
    run ls -ld /etc/viikko5
    run ls -l /etc/viikko5/
    run ls -ld /run/viikko5
    run ls -l /run/viikko5/
    run id viikko5
    run id deploy
    run id www-data
    echo; echo '$ mariadb -e "SHOW GRANTS FOR ..."   (hashes replaced)'
    for u in viikko5 viikko5_schema; do
        mariadb -N -e "SHOW GRANTS FOR '$u'@'localhost'" | sed -E "s/PASSWORD '[^']*'/PASSWORD '<hash removed>'/"
    done
    run cat /etc/sudoers.d/viikko5-deploy
    echo; echo '$ cut -d" " -f1 /home/deploy/.ssh/authorized_keys   (options only)'
    cut -d' ' -f1 /home/deploy/.ssh/authorized_keys
    run ollama list
    run ollama ps
    run free -h
    run df -h /
    run ss -ltnp
    run ufw status
    run systemctl is-enabled viikko5 ollama nginx mariadb
    echo; echo '$ mariadb viikko5 -e "SELECT COUNT(*), COUNT(DISTINCT session_id) FROM messages"'
    mariadb viikko5 -e "SELECT COUNT(*) AS messages, COUNT(DISTINCT session_id) AS conversations FROM messages"
} > "$OUT"
chown kalle:kalle "$OUT"
chmod 600 "$OUT"
echo "wrote $OUT"
