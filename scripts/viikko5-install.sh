#!/usr/bin/env bash
# Root part of the deploy. server-setup.sh installs this as /usr/local/sbin/viikko5-install
# (root:root 755) and sudoers lets user deploy run it without arguments. The copy on the
# server is not updated by deploys: changing it needs an admin to run server-setup.sh again.
#
# Uses files from the deployed repo: deploy/sql/schema.sql, deploy/nginx/viikko5.conf,
# deploy/systemd/viikko5.service. Does not touch other sites or services.
set -euo pipefail
umask 022

APP=/opt/viikko5/app
SNIPPET=/etc/nginx/snippets/viikko5.conf
UNIT=/etc/systemd/system/viikko5.service

echo "-- schema (db user viikko5_schema, privileges only on database viikko5)"
mariadb --defaults-extra-file=/etc/viikko5/schema.cnf viikko5 < "$APP/deploy/sql/schema.sql"

echo "-- nginx snippet"
if ! grep -qsE '^\s*include\s+snippets/viikko5\.conf\s*;' /etc/nginx/sites-enabled/*; then
    echo "the include line for snippets/viikko5.conf is missing from the site" >&2
    exit 1
fi
cp -p "$SNIPPET" "$SNIPPET.bak"
install -m 644 -o root -g root "$APP/deploy/nginx/viikko5.conf" "$SNIPPET"
if ! nginx -t; then
    echo "nginx -t failed, putting the old snippet back" >&2
    mv "$SNIPPET.bak" "$SNIPPET"
    exit 1
fi
rm -f "$SNIPPET.bak"

echo "-- systemd unit"
NEW_UNIT="$APP/deploy/systemd/viikko5.service"
# the unit comes from git, refuse one that would run as someone else
if [[ $(grep -cE '^User=' "$NEW_UNIT") != 1 ]] || ! grep -qx 'User=viikko5' "$NEW_UNIT" \
   || ! grep -qx 'Group=viikko5' "$NEW_UNIT" || grep -qE '^Exec[A-Za-z]*=[-@:!+]*[+!]' "$NEW_UNIT"; then
    echo "refusing unit: it must run as User=viikko5 Group=viikko5 without + or ! exec prefixes" >&2
    exit 1
fi
install -m 644 -o root -g root "$NEW_UNIT" "$UNIT"
systemctl daemon-reload
systemctl enable --quiet viikko5
# only our own service is restarted, nginx only reloads
systemctl restart viikko5
systemctl reload nginx
echo "-- done"
