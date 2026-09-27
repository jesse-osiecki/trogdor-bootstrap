#!/bin/bash
# Package a kernel built in a kernel source tree (make ARCH=arm64 LLVM=1) into a
# depthcharge kpart image without touching the installed kernel package, then
# optionally flash it. For testing kernel trees directly (linux-next, a branch
# being prepared for upstream); a packaged kernel goes through
# `patch-refresh.sh kernel --test` instead.
#
#   build-kpart.sh                          -> $OUT_BASE/<release>/vmlinuz.kpart
#   build-kpart.sh --flash /dev/mmcblk1p4   -> also dd it to that partition
#
# Env: SRC (kernel tree, default $CODE/linux), OUT_BASE (default $CODE/out),
#      DTB_GLOB (default the wormdingler DTBs), CODE (default ~/code).
# Steps: modules_install into /lib/modules/<release>, dtbs into a staging dir,
# initramfs via mkinitfs for <release>, depthchargectl build, size check.
# Afterwards mark the slot unproven: sudo cgpt add -i 4 -P 15 -T 1 -S 0 <disk>
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CODE=${CODE:-$HOME/code}
SRC=${SRC:-$CODE/linux}
OUT_BASE=${OUT_BASE:-$CODE/out}
FLAVOR=postmarketos-qcom-sc7180
BOARD=qc7180
DTB_GLOB=${DTB_GLOB:-sc7180-trogdor-wormdingler-*.dtb}
FLASH_TARGET=""
[ "${1:-}" = "--flash" ] && FLASH_TARGET="$2"

cd "$SRC"
REL=$(cat include/config/kernel.release)
KREL=/usr/share/kernel/$FLAVOR/kernel.release
echo "==> kernel release: $REL"
[ "$REL" != "$(cat "$KREL")" ] || { echo "refusing: release collides with the installed kernel package (set CONFIG_LOCALVERSION)"; exit 1; }

OUT="$OUT_BASE/$REL"
WORK="$OUT/work"
rm -rf "$WORK"; mkdir -p "$WORK/dtbs" "$OUT"

echo "==> installing modules to /lib/modules/$REL"
make -s ARCH=arm64 LLVM=1 LOCALVERSION="" INSTALL_MOD_PATH="$WORK/modroot" INSTALL_MOD_STRIP=1 modules_install
sudo rm -rf "/lib/modules/$REL"
sudo cp -a "$WORK/modroot/lib/modules/$REL" /lib/modules/
sudo depmod "$REL"

echo "==> collecting kernel and dtbs ($DTB_GLOB)"
cp arch/arm64/boot/Image.gz "$WORK/vmlinuz"
cp arch/arm64/boot/dts/qcom/$DTB_GLOB "$WORK/dtbs/"
ls "$WORK/dtbs"

echo "==> building initramfs for $REL with mkinitfs"
# mkinitfs takes the kernel release from this file; point it at ours temporarily.
sudo cp "$KREL" "$KREL.stock"
echo "$REL" | sudo tee "$KREL" >/dev/null
trap 'sudo mv -f "$KREL.stock" "$KREL"' EXIT
sudo env PATH="$HERE/fake-boot-deploy:$PATH" mkinitfs -d "$WORK"
sudo mv -f "$KREL.stock" "$KREL"; trap - EXIT
ls -la "$WORK"

# kernel cmdline exactly as boot-deploy assembles it
. /usr/share/deviceinfo/deviceinfo
BOOT_UUID=$(awk '$2=="/boot"{print $1}' /etc/fstab | sed 's/^UUID=//')
ROOT_UUID=$(awk '$2=="/"{print $1}' /etc/fstab | sed 's/^UUID=//')
if [ -f /etc/crypttab ]; then
	ROOT_UUID=$(awk '$1=="root"{print $2}' /etc/crypttab | sed 's/^UUID=//')
fi
ROOT_OPTS=$(awk '$2=="/"{print $4}' /etc/fstab)
CMDLINE="$(generate-kernel-cmdline) pmos_boot_uuid=$BOOT_UUID pmos_root_uuid=$ROOT_UUID pmos_rootfsopts=$ROOT_OPTS"
echo "==> cmdline: $CMDLINE"

echo "==> depthchargectl build"
depthchargectl build --root none --board "$BOARD" \
	--kernel "$WORK/vmlinuz" \
	--kernel-cmdline "$CMDLINE" \
	--initramfs "$WORK/initramfs" \
	--fdtdir "$WORK/dtbs" \
	--compress "${deviceinfo_depthcharge_compression:-none}" \
	--output "$OUT/vmlinuz.kpart"
ls -la "$OUT/vmlinuz.kpart"
futility vbutil_kernel --verify "$OUT/vmlinuz.kpart" | head -5 || true

if [ -n "$FLASH_TARGET" ]; then
	SIZE=$(stat -c %s "$OUT/vmlinuz.kpart")
	PSIZE=$(sudo blockdev --getsize64 "$FLASH_TARGET")
	[ "$SIZE" -le "$PSIZE" ] || { echo "kpart ($SIZE) larger than $FLASH_TARGET ($PSIZE)"; exit 1; }
	echo "==> flashing to $FLASH_TARGET"
	sudo dd if="$OUT/vmlinuz.kpart" of="$FLASH_TARGET" bs=4M status=none conv=fsync
	echo "flashed; now set cgpt priority/tries on that partition"
fi
echo "done: $OUT/vmlinuz.kpart"
