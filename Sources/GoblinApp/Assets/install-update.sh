#!/bin/sh
# The app stages and verifies the signed bundle before launching this helper.
# All paths are positional arguments, never interpolated into shell source.
set -eu
pid=$1
destination=$2
staging=$3
log=$4
exec >>"$log" 2>&1
umask 077

case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
case "$staging" in "$(dirname "$destination")"/.goblin-update-*) ;; *) exit 1 ;; esac
payload="$staging/payload/gob.lin.app"
previous="$staging/previous.app"
test -d "$payload"

# Shutdown drains recognition and history writes. Never replace a running app.
attempt=0
while /bin/kill -0 "$pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 120 ]; then
        echo 'Update cancelled: gob.lin did not exit; installed app unchanged.'
        rm -rf "$staging"
        exit 1
    fi
    /bin/sleep 1
done

echo 'Installing verified gob.lin update.'
if ! /bin/mv "$destination" "$previous"; then
    echo 'Could not move installed app; installed app unchanged.'
    rm -rf "$staging"
    exit 1
fi
if ! /bin/mv "$payload" "$destination"; then
    /bin/mv "$previous" "$destination"
    /usr/bin/open -n "$destination"
    echo 'Installation failed; restored previous app.'
    rm -rf "$staging"
    exit 1
fi
if ! /usr/bin/open -n "$destination"; then
    /bin/mv "$destination" "$staging/failed.app"
    /bin/mv "$previous" "$destination"
    /usr/bin/open -n "$destination"
    echo 'Relaunch failed; restored previous app.'
    rm -rf "$staging"
    exit 1
fi
echo 'Update installed and relaunched.'
rm -rf "$staging"
