# kernel_test_p4 <apk>: make a depthcharge kpart from a built kernel apk and flash it to
# the unproven test slot p4 (created by make-kernel-b-partition.sh). kernel-deadman +
# camera-selftest judge the boot. Env: EMMC (default /dev/mmcblk1), DTB_GLOB (default the
# wormdingler DTBs). Sourced by patch-refresh.sh, which sets HERE, CODE, PKG and say().
kernel_test_p4() {
	DISK=${EMMC:-/dev/mmcblk1}
	APK=$1; T=$(mktemp -d "$CODE/.refresh-apk.XXXXXX"); tar -xzf "$APK" -C "$T" 2>/dev/null || true
	REL_STR=$(ls "$T/lib/modules"); echo "kernel release in package: $REL_STR"
	sudo rm -rf "/lib/modules/$REL_STR"; sudo cp -a "$T/lib/modules/$REL_STR" /lib/modules/; sudo depmod "$REL_STR"
	W=$CODE/out/$REL_STR; rm -rf "$W/work"; mkdir -p "$W/work/dtbs"
	cp "$T/boot/vmlinuz"* "$W/work/vmlinuz"; cp "$T"/boot/dtbs/qcom/${DTB_GLOB:-sc7180-trogdor-wormdingler-*.dtb} "$W/work/dtbs/"
	KREL=/usr/share/kernel/${PKG#linux-}/kernel.release
	sudo cp "$KREL" "$KREL.stock"; echo "$REL_STR" | sudo tee "$KREL" >/dev/null
	sudo env PATH="$HERE/scripts/fake-boot-deploy:$PATH" mkinitfs -d "$W/work"; sudo mv -f "$KREL.stock" "$KREL"
	. /usr/share/deviceinfo/deviceinfo
	BOOT_UUID=$(awk '$2=="/boot"{print $1}' /etc/fstab | sed 's/^UUID=//'); ROOT_UUID=$(awk '$1=="root"{print $2}' /etc/crypttab | sed 's/^UUID=//')
	CMDLINE="$(generate-kernel-cmdline 2>/dev/null) pmos_boot_uuid=$BOOT_UUID pmos_root_uuid=$ROOT_UUID pmos_rootfsopts=$(awk '$2=="/"{print $4}' /etc/fstab)"
	depthchargectl build --root none --board qc7180 --kernel "$W/work/vmlinuz" --kernel-cmdline "$CMDLINE" \
		--initramfs "$W/work/initramfs" --fdtdir "$W/work/dtbs" --compress "${deviceinfo_depthcharge_compression:-none}" --output "$W/vmlinuz.kpart" >/dev/null
	rm -rf "$T"
	say "flashing $W/vmlinuz.kpart to ${DISK}p4 as UNPROVEN (one try, not successful)"
	sudo dd if="$W/vmlinuz.kpart" of="${DISK}p4" bs=1M conv=fsync status=none
	sudo cgpt add -i 4 -P 15 -T 1 -S 0 "$DISK"; sudo cgpt show -i 4 "$DISK" | grep Attr
	cat <<MSG

Now: sudo systemctl reboot
  - good boot: desktop appears, run 'sudo kernel-keep' within 5 min, check 'cam -l' and /boot/camtest
  - bad boot: kernel-deadman reboots to the failsafe (p1) by itself; read /boot/livelog
Then: patch-refresh.sh kernel --install
MSG
}
