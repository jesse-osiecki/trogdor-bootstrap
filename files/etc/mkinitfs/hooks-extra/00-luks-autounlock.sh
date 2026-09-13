#!/bin/sh
# Unlock the LUKS root with the keyfile shipped in the initramfs so the device
# boots unattended (no unl0kr prompt). Runs from /hooks-extra, before
# unlock_root_partition, which then sees the mapping already active.
KEY=/etc/luks-autounlock.key
[ -f "$KEY" ] || exit 0
command -v cryptsetup >/dev/null || exit 0
cryptsetup status root 2>/dev/null | grep -qwi active && exit 0
i=0
while [ $i -lt 40 ]; do
	dev=$(blkid -t PARTLABEL=pmOS_root -o device 2>/dev/null | head -n1)
	[ -z "$dev" ] && dev=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -n1)
	if [ -n "$dev" ] && cryptsetup isLuks "$dev" 2>/dev/null; then
		echo "[luks-autounlock] opening $dev with keyfile"
		if cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue \
			open --key-file "$KEY" "$dev" root; then
			exit 0
		fi
		echo "[luks-autounlock] keyfile unlock failed, falling back to prompt"
		exit 0
	fi
	sleep 0.25
	i=$((i + 1))
done
echo "[luks-autounlock] root partition not found, falling back to prompt"
