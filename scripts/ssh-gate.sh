#!/usr/bin/env bash
# Forced command for the GitHub Actions key in /home/deploy/.ssh/authorized_keys.
# server-setup.sh installs it as /usr/local/sbin/viikko5-ssh-gate. The key can do two things:
#   rsync files into /opt/viikko5/app       (rrsync, write only)
#   deploy <sha>                             (runs scripts/deploy.sh)
# Anything else, like a shell, is refused.
set -euo pipefail

cmd="${SSH_ORIGINAL_COMMAND:-}"
case "$cmd" in
    "rsync --server "*)
        exec /usr/bin/rrsync -wo /opt/viikko5/app
        ;;
    "deploy "*)
        rev="${cmd#deploy }"
        [[ $rev =~ ^[0-9a-f]{40}$ ]] || { echo "bad sha" >&2; exit 1; }
        exec /bin/bash /opt/viikko5/app/scripts/deploy.sh "$rev"
        ;;
    *)
        echo "this key can only rsync to /opt/viikko5/app and run deploy <sha>" >&2
        exit 1
        ;;
esac
