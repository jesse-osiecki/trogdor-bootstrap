#!/bin/sh
# Drift check: does the live system still match this repo?
#   1. manifest files:  diff repo copy vs system
#   2. line edits:      keyd ids (keyboard hash, EC buttons exclusion), zram pct
#   3. apk audit:       package-owned files changed under /etc (needs root)
#   4. unmanaged:       local files in the directories we manage that the
#                       manifest does not know about
#   --ansible           also run ansible-playbook --check --diff (templates,
#                       packages, units). Exit 1 if anything drifted.
set -u
cd "$(dirname "$0")"
rc=0
say() { printf '\n==> %s\n' "$*"; }

say "1. managed files"
grep -vE '^\s*(#|$)' manifest.txt | while read -r role mode path; do
	sys=$(printf '%s' "$path" | sed "s|^~|$HOME|")
	repo="files$(printf %s "$path" | sed "s|^~|/HOME|")"
	if [ ! -e "$sys" ]; then
		echo "   absent  [$role] $path"
	elif [ ! -f "$repo" ]; then
		echo "   NOREPO  [$role] $path"; exit 1
	elif ! diff -q "$repo" "$sys" >/dev/null; then
		echo "   DRIFT   [$role] $path"; diff -u "$repo" "$sys" | sed 's/^/           /' | head -20; exit 1
	else
		echo "   ok      [$role] $path"
	fi
done || rc=1

say "2. line edits"
hash=$(sed -n 's/^keyd_keyboard_hash: *//p' inventory/host_vars/"$(hostname)".yml group_vars/all.yml | head -1)
if grep -qx "k:18d1:5057:$hash" /etc/keyd/default.conf; then echo "   ok      keyd $hash"; else echo "   DRIFT   keyd: $(grep 18d1:5057 /etc/keyd/default.conf)"; rc=1; fi
echash=$(sed -n 's/^keyd_ec_buttons_hash: *//p' inventory/host_vars/"$(hostname)".yml group_vars/all.yml | head -1)
if grep -qx -- "-0000:0000:$echash" /etc/keyd/default.conf && grep -n -E '^(-0000:0000:|k:0000:0000)' /etc/keyd/default.conf | head -1 | grep -q -- '-0000'; then echo "   ok      keyd excludes cros_ec_buttons $echash"; else echo "   DRIFT   keyd: cros_ec_buttons exclusion missing or after k:0000:0000"; rc=1; fi
pct=$(sed -n 's/^zram_swap_pct: *"\(.*\)"/\1/p' group_vars/all.yml)
if grep -qx "deviceinfo_zram_swap_pct=\"$pct\"" /etc/deviceinfo; then echo "   ok      zram $pct%"; else echo "   DRIFT   zram: $(grep zram_swap_pct /etc/deviceinfo || echo unset)"; rc=1; fi

say "3. apk audit: package-owned files modified under /etc (U = changed)"
# Expected U lines: deviceinfo, keyd/default.conf, pam.d/kde-fingerprint (ours);
# passwd/shadow/group/hosts/hostname/fstab/mtab/shells and tuned/* are the installer's.
audit=$(if sudo -n true 2>/dev/null; then sudo apk audit; else apk audit 2>/dev/null; fi)
printf '%s\n' "$audit" | grep '^U ' | grep -vE ' etc/(passwd|shadow|group|hosts|hostname|fstab|mtab|shells|tuned/|modprobe.d/tuned)' | sed 's/^/   /'
sudo -n true 2>/dev/null || echo "   (partial: run with passwordless sudo for a full audit)"

say "4. unmanaged local files"
# Paths written by templates/tasks rather than the manifest:
known="/etc/sudoers.d/$(id -un)-nopasswd /etc/mkinitfs/files-extra/00-luks-autounlock.files"
for d in /usr/local/sbin /usr/local/bin /usr/lib/systemd/system-sleep /etc/sysctl.d /etc/sudoers.d /etc/mkinitfs/hooks-extra /etc/mkinitfs/files-extra; do
	[ -d "$d" ] || continue
	for f in "$d"/*; do
		[ -f "$f" ] || continue
		case "$f" in /etc/keyd/default.conf.bak-*) continue;; esac
		grep -q " $f\$" manifest.txt || case " $known " in *" $f "*) ;; *) echo "   unmanaged $f";; esac
	done
done
for f in /etc/systemd/system/*.service; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	grep -q " $f\$" manifest.txt || echo "   unmanaged $f"
done

if [ "${1:-}" = "--ansible" ] && command -v ansible-playbook >/dev/null; then
	say "5. ansible --check --diff"
	shift
	if sudo -n true 2>/dev/null; then set -- "$@"; else set -- "$@" --ask-become-pass; fi
	ansible-playbook site.yml --limit "$(hostname)" -e "device_user=$(id -un)" --check --diff "$@" || rc=1
fi
[ $rc -eq 0 ] && echo "
no drift" || echo "
DRIFT detected: run ./sync.sh to pull the system into the repo, or ./bootstrap.sh to push the repo to the system"
exit $rc
