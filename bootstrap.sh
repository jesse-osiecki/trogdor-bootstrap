#!/bin/sh
# Bootstrap this trogdor device from the repo. POSIX sh on purpose: a fresh
# postmarketOS install has only busybox ash. Installs bash and ansible-core on
# the first run, then applies site.yml locally for $(hostname).
#
#   ./bootstrap.sh                 apply everything enabled for this host
#   ./bootstrap.sh --tags base     only one role
#   ./bootstrap.sh --check --diff  dry run (what would change)
#   ./bootstrap.sh -e enable_unattended=true   turn a role on for this run
#   LUKS_PASSPHRASE=... ./bootstrap.sh --tags unattended
set -eu
cd "$(dirname "$0")"
host=$(hostname)

need=""
for p in bash python3 ansible-core; do
	apk info -e "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then
	echo "==> installing:$need"
	sudo apk add $need
fi

if ! grep -q "^    $host:" inventory/hosts.yml; then
	echo "!! $host is not in inventory/hosts.yml. Add it (ansible_connection: local)" >&2
	echo "   and create inventory/host_vars/$host.yml to switch roles on." >&2
	exit 1
fi

set -- --limit "$host" "$@"
if [ -n "${LUKS_PASSPHRASE:-}" ]; then
	set -- "$@" -e "luks_passphrase=$LUKS_PASSPHRASE"
fi
if ! sudo -n true 2>/dev/null; then
	set -- "$@" --ask-become-pass
fi
exec ansible-playbook site.yml "$@"
