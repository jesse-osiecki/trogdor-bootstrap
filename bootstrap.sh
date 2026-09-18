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

# Per-device files are gitignored; create them from the examples on first run.
if [ ! -f inventory/hosts.yml ]; then
	printf 'all:\n  hosts:\n    %s:\n      ansible_connection: local\n' "$host" > inventory/hosts.yml
	echo "==> wrote inventory/hosts.yml for $host"
elif ! grep -q "^    $host:" inventory/hosts.yml; then
	echo "!! $host is not in inventory/hosts.yml (add it with ansible_connection: local)" >&2
	exit 1
fi
if [ ! -f "inventory/host_vars/$host.yml" ]; then
	cp inventory/host_vars/example.yml "inventory/host_vars/$host.yml"
	echo "==> wrote inventory/host_vars/$host.yml from the example; edit it to switch roles on"
fi

set -- --limit "$host" -e "device_user=$(id -un)" "$@"
if [ -n "${LUKS_PASSPHRASE:-}" ]; then
	set -- "$@" -e "luks_passphrase=$LUKS_PASSPHRASE"
fi
if ! sudo -n true 2>/dev/null; then
	set -- "$@" --ask-become-pass
fi
exec ansible-playbook site.yml "$@"
