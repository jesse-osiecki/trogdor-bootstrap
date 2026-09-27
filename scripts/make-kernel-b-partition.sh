#!/bin/bash
# Create a second ChromeOS kernel partition (KERN-B, the test slot p4) on the
# eMMC by shrinking the 512 MiB pmOS_boot (ext2, /boot) partition to 256 MiB and
# using the freed 256 MiB for a "pmOS_kernel_b" partition. The kernel-deadman,
# kernel-keep and patch-refresh.sh --test tooling expects this layout.
#
# Layout before (pmbootstrap default):  Layout after:
#   p1 pmOS_kernel  128M                  p1 pmOS_kernel   128M  (stock kernel)
#   p2 pmOS_boot    512M                  p2 pmOS_boot     256M
#   p3 pmOS_root    rest                  p4 pmOS_kernel_b 256M  (test kernels)
#                                         p3 pmOS_root     rest  (unchanged)
#
# DESTRUCTIVE (repartitions the boot disk). DRY RUN by default: prints every
# command. Run with --do-it to apply. Requires root. Refuses unless the current
# layout is exactly the pmbootstrap default above.
#
#   EMMC=/dev/mmcblk1 BACKUP=/var/backups/kernel-b ./make-kernel-b-partition.sh [--do-it]
set -euo pipefail

DISK=${EMMC:-/dev/mmcblk1}
BOOT_PART=${DISK}p2
BACKUP=${BACKUP:-/var/backups/kernel-b}
P2_OLD_SIZE=1048576      # 512 MiB in 512-byte sectors
P2_NEW_SIZE=524288       # 256 MiB
P4_SIZE=524288           # 256 MiB, ends exactly at the p3 start

run() { echo "+ $*"; if [ "$DOIT" = 1 ]; then "$@"; fi; }

DOIT=0; [ "${1:-}" = "--do-it" ] && DOIT=1
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

# sanity: verify the current layout matches expectations
P2_START=$(cgpt show -i 2 -b "$DISK")
P4_START=$((P2_START + P2_NEW_SIZE))
[ "$(cgpt show -i 2 -s "$DISK")" = "$P2_OLD_SIZE" ] || { echo "p2 is not 512 MiB, abort"; cgpt show "$DISK"; exit 1; }
[ "$(cgpt show -i 3 -b "$DISK")" = "$((P4_START + P4_SIZE))" ] || { echo "p3 does not start right after p2, abort"; exit 1; }
[ "$(cgpt show -i 4 -s "$DISK")" = 0 ] || { echo "p4 already exists, abort"; exit 1; }

mkdir -p "$BACKUP"
run sh -c "dd if=$DISK of=$BACKUP/gpt-head.bin bs=512 count=34 status=none"
run sh -c "cgpt show $DISK > $BACKUP/cgpt-before.txt"

run umount /boot
run e2fsck -f -y "$BOOT_PART"
run resize2fs "$BOOT_PART" 256M
# resize the GPT entry in place (same start, new size)
run cgpt add -i 2 -b "$P2_START" -s "$P2_NEW_SIZE" "$DISK"
# new kernel partition, initially lower priority than the stock one
run cgpt add -i 4 -b "$P4_START" -s "$P4_SIZE" -t kernel -l pmOS_kernel_b -P 5 -T 0 -S 0 "$DISK"
run partx -u --nr 2 "$DISK"
run partx -a --nr 4 "$DISK"
run mount /boot
run cgpt show "$DISK"
echo "done (dry-run unless --do-it); backups in $BACKUP"
