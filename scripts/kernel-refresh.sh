#!/bin/sh
# kernel-refresh.sh: carry the wormdingler camera patches to a newer
# linux-postmarketos-qcom-sc7180 kernel, one guarded stage at a time.
#
#   kernel-refresh.sh                 check: compare our aport with upstream pmaports
#   kernel-refresh.sh --dry-run       + rebase pmaports and the kernel patches on
#                                     throw-away branches, show what would change
#   kernel-refresh.sh --apply         rebase for real, export the patches into the
#                                     aport, regenerate APKBUILD + checksums, commit
#   kernel-refresh.sh --build         + abuild the package (native, ~2 h on the tablet)
#   kernel-refresh.sh --test          + make a kpart from the built apk and flash it
#                                     to the test slot p4 (unproven: -T 1 -S 0). You
#                                     reboot; kernel-deadman + camera-selftest judge it.
#   kernel-refresh.sh --install       install the apk (pins it in /etc/apk/world;
#                                     boot-deploy rewrites p1), then sync the bootstrap repo
#
# Options: --track REF (pmaports ref we follow, default origin/main),
#          --kernel-version X.Y.Z (rebase onto this stable tag instead of upstream's pkgver),
#          --force (run even if upstream has nothing new).
#
# The script stops at anything that needs a human: a rebase conflict, a failed
# build, and always before a reboot or an install. Commits are authored as Jesse.
# Sources of truth: kernel patches = git branch wormdingler-camera-<ver> in ~/code/linux;
# config additions = scripts/kernel-config-fragment in this repo.
set -eu

CODE=${CODE:-$HOME/code}
PMAPORTS=${PMAPORTS:-$CODE/pmaports}; PMBRANCH=wormdingler-camera
LINUX=${LINUX:-$CODE/linux}; KPREFIX=wormdingler-camera-
KPKG=device/community/linux-postmarketos-qcom-sc7180
PKG=linux-postmarketos-qcom-sc7180
HERE=$(cd "$(dirname "$0")/.." && pwd)
FRAGMENT=$HERE/scripts/kernel-config-fragment
AUTHOR_NAME="Jesse Osiecki"; AUTHOR_EMAIL="jesse@jjo.ninja"
TESTSLOT=/dev/mmcblk1p4; DISK=/dev/mmcblk1

TRACK=origin/main; MODE=check; FORCE=0; WANTVER=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) MODE=dryrun;; --apply) MODE=apply;; --build) MODE=build;;
	--test) MODE=test;; --install) MODE=install;; --force) FORCE=1;;
	--track) TRACK=$2; shift;; --kernel-version) WANTVER=$2; shift;;
	-h|--help) sed -n '2,25p' "$0"; exit 0;;
	*) echo "unknown option $1" >&2; exit 64;;
	esac; shift
done

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'STOP: %s\n' "$*" >&2; exit "${2:-1}"; }
apkvar() { git -C "$PMAPORTS" show "$1:$KPKG/APKBUILD" | sed -n "s/^$2=//p" | head -1; }

# ---------------------------------------------------------------- 1. check
say "fetching pmaports ($TRACK)"
git -C "$PMAPORTS" fetch -q origin "${TRACK#origin/}"
UPVER=$(apkvar "$TRACK" pkgver); UPREL=$(apkvar "$TRACK" pkgrel)
OURVER=$(apkvar "$PMBRANCH" pkgver); OURREL=$(apkvar "$PMBRANCH" pkgrel)
NEWVER=${WANTVER:-$UPVER}
echo "upstream $TRACK: $PKG $UPVER-r$UPREL"
echo "our branch $PMBRANCH: $PKG $OURVER-r$OURREL"
echo "target kernel: $NEWVER"
AHEAD=$(git -C "$PMAPORTS" rev-list --count "$PMBRANCH..$TRACK")
APORT_CHANGED=$(git -C "$PMAPORTS" log --oneline "$(git -C "$PMAPORTS" merge-base "$PMBRANCH" "$TRACK")..$TRACK" -- "$KPKG" | wc -l)
echo "pmaports: $AHEAD upstream commits since our base, $APORT_CHANGED of them touch $KPKG"
if [ "$NEWVER" = "$OURVER" ] && [ "$APORT_CHANGED" = 0 ] && [ "$FORCE" = 0 ] && [ "$MODE" != install ] && [ "$MODE" != test ]; then
	echo "nothing new: same kernel version, aport unchanged upstream (use --force to rebase anyway)"
	exit 0
fi
[ "$MODE" = check ] && exit 0

# ---------------------------------------------------------------- 2. rebase pmaports
if [ "$MODE" = dryrun ] || [ "$MODE" = apply ]; then
	say "rebasing pmaports branch onto $TRACK"
	[ -z "$(git -C "$PMAPORTS" status --porcelain --untracked-files=no)" ] || die "pmaports working tree has uncommitted changes"
	if [ "$MODE" = dryrun ]; then
		PMWORK=$(mktemp -d "$CODE/.refresh-pmaports.XXXXXX"); PMREF=refresh-dryrun
		git -C "$PMAPORTS" worktree add -q -B "$PMREF" "$PMWORK" "$PMBRANCH"
	else
		PMWORK=$PMAPORTS; PMREF=$PMBRANCH
		git -C "$PMAPORTS" checkout -q "$PMBRANCH"
	fi
	if ! git -C "$PMWORK" rebase -q "$TRACK" >/dev/null 2>&1; then
		git -C "$PMWORK" diff --name-only --diff-filter=U | sed 's/^/  conflict: /'
		git -C "$PMWORK" rebase --abort
		die "pmaports rebase conflicts (branch left untouched); resolve by hand: cd $PMAPORTS && git rebase $TRACK" 2
	fi
	echo "pmaports rebase clean: $(git -C "$PMWORK" log --oneline -1 | cut -c1-80)"

# ---------------------------------------------------------------- 3. rebase kernel patches
	say "rebasing kernel patches onto v$NEWVER"
	git -C "$LINUX" rev-parse -q --verify "v$NEWVER" >/dev/null 2>&1 || git -C "$LINUX" fetch -q origin "tag" "v$NEWVER"
	OLDBR=$KPREFIX$OURVER; NEWBR=$KPREFIX$NEWVER
	git -C "$LINUX" rev-parse -q --verify "$OLDBR" >/dev/null || die "kernel branch $OLDBR not found in $LINUX"
	KWORK=$(mktemp -d "$CODE/.refresh-linux.XXXXXX")
	if [ "$MODE" = dryrun ]; then KREF=refresh-dryrun; else KREF=$NEWBR; fi
	git -C "$LINUX" worktree add -q -B "$KREF" "$KWORK" "$OLDBR"
	# Rebase, skipping commits that stable already carries (same subject, e.g. the
	# CCI runtime-PM fixes that reached 6.18.y after .40) or that are listed in
	# scripts/kernel-patch-skip (Jesse's standing decision to drop a patch).
	SKIPLIST=$HERE/scripts/kernel-patch-skip
	REBASE_OK=1
	if ! git -C "$KWORK" rebase -q "v$NEWVER" >/dev/null 2>&1; then
		while [ -d "$KWORK/.git/rebase-merge" ] || [ -d "$(git -C "$KWORK" rev-parse --git-path rebase-merge)" ]; do
			subj=$(git -C "$KWORK" log -1 --format=%s REBASE_HEAD)
			if git -C "$LINUX" log --format=%s "v$OURVER..v$NEWVER" | grep -Fxq "$subj"; then
				echo "  already in stable, skipping: $subj"
			elif [ -f "$SKIPLIST" ] && grep -Fxq "$subj" "$SKIPLIST"; then
				echo "  on the skip list, dropping: $subj"
			else
				REBASE_OK=0; break
			fi
			git -C "$KWORK" rebase --skip >/dev/null 2>&1 && break || true
		done
	fi
	if [ "$REBASE_OK" = 0 ]; then
		echo "  conflicting patch: $(git -C "$KWORK" log -1 --format=%s REBASE_HEAD)"
		git -C "$KWORK" diff --name-only --diff-filter=U | sed 's/^/  conflict: /'
		if [ "$MODE" = dryrun ]; then
			git -C "$KWORK" rebase --abort; git -C "$LINUX" worktree remove --force "$KWORK"; git -C "$LINUX" branch -q -D "$KREF"
			[ "$PMWORK" != "$PMAPORTS" ] && { git -C "$PMAPORTS" worktree remove --force "$PMWORK"; git -C "$PMAPORTS" branch -q -D "$PMREF"; }
			die "kernel patches conflict on v$NEWVER (dry run, nothing kept)" 2
		fi
		die "kernel patches conflict on v$NEWVER. Resolve in $KWORK (git rebase --continue), then rerun with --apply" 2
	fi
	NPATCH=$(git -C "$KWORK" rev-list --count "v$NEWVER..$KREF")
	echo "kernel rebase clean: $NPATCH patches on v$NEWVER"

# ---------------------------------------------------------------- 4. export into the aport
	say "regenerating the aport from $TRACK + our patches"
	APORT=$PMWORK/$KPKG
	git -C "$PMWORK" rm -q -r --cached "$KPKG" && rm -rf "$APORT"   # drop our old patch files
	git -C "$PMWORK" checkout -q "$TRACK" -- "$KPKG"                # pristine upstream files
	UPPATCHES=$(sed -n '/^source="/,/^"/p' "$APORT/APKBUILD" | grep -c '\.patch$' || true)
	git -C "$KWORK" format-patch -q --no-signature --start-number "$((UPPATCHES+1))" -o "$APORT" "v$NEWVER..$KREF"
	OURPATCHES=$(ls "$APORT" | grep -E '^[0-9]{4}-.*\.patch$' | sort | tail -n "+$((UPPATCHES+1))")
	# pkgrel: one above upstream when we ship the same kernel, r1 when we are ahead of it
	if [ "$NEWVER" = "$UPVER" ]; then NEWREL=$((UPREL+1)); else NEWREL=1; fi
	python3 - "$APORT/APKBUILD" "$NEWVER" "$NEWREL" $OURPATCHES <<'EOF'
import sys,re
p,ver,rel,*patches=sys.argv[1:]
s=open(p).read()
s=re.sub(r'^pkgver=.*$', 'pkgver=%s'%ver, s, count=1, flags=re.M)
s=re.sub(r'^pkgrel=\d+$', 'pkgrel=%s'%rel, s, count=1, flags=re.M)
ins=''.join('\t%s\n'%x for x in patches)
s=s.replace('\t$_config\n', ins+'\t$_config\n',1)
open(p,'w').write(s)
EOF
	if [ -s "$FRAGMENT" ]; then
		CFG=$APORT/$(sed -n 's/^_config="\(.*\)"/\1/p' "$APORT/APKBUILD" | sed "s/\$_flavor/${PKG#linux-}/; s/\$arch/aarch64/")
		grep -vE '^\s*(#|$)' "$FRAGMENT" | while read -r line; do
			name=${line%%=*}; val=${line#*=}
			case "$val" in y) "$LINUX/scripts/config" --file "$CFG" --enable "${name#CONFIG_}";;
			m) "$LINUX/scripts/config" --file "$CFG" --module "${name#CONFIG_}";;
			n) "$LINUX/scripts/config" --file "$CFG" --disable "${name#CONFIG_}";;
			*) "$LINUX/scripts/config" --file "$CFG" --set-val "${name#CONFIG_}" "$val";; esac
		done
	fi
	echo "abuild checksum (downloads linux-$NEWVER.tar.xz on first use, ~150 MB)"
	(cd "$APORT" && abuild checksum >/dev/null 2>&1) || die "abuild checksum failed (is the tarball for $NEWVER downloadable?)"
	git -C "$PMWORK" add -A "$KPKG"
	git -C "$PMWORK" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -q --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" \
		-m "$PKG: camera support for google-trogdor wormdingler ($NEWVER)" \
		-m "Rebased the wormdingler camera patch set onto $NEWVER ($NPATCH patches, branch $NEWBR in ~/code/linux). Sensor drivers enabled as modules via scripts/kernel-config-fragment." \
		|| die "nothing to commit in the aport (already up to date?)"
	echo "aport now: $(apkvar "$PMREF" pkgver)-r$(apkvar "$PMREF" pkgrel), $(ls "$APORT"/*.patch | wc -l) patches"
	git -C "$PMWORK" show --stat --format='%h %s' HEAD | tail -4

	if [ "$MODE" = dryrun ]; then
		say "dry run: APKBUILD diff against our current branch"
		git -C "$PMWORK" diff "$PMBRANCH" "$PMREF" -- "$KPKG/APKBUILD" | head -60
		git -C "$PMAPORTS" worktree remove --force "$PMWORK"; git -C "$PMAPORTS" branch -q -D "$PMREF"
		git -C "$LINUX" worktree remove --force "$KWORK"; git -C "$LINUX" branch -q -D "$KREF"
		say "dry run complete, nothing kept. Next: kernel-refresh.sh --apply"
		exit 0
	fi
	git -C "$LINUX" worktree remove --force "$KWORK"
	TAGV="$NEWVER-r$NEWREL"
	git -C "$LINUX" tag -f "wormdingler-camera/$TAGV" "$NEWBR" >/dev/null
	git -C "$PMAPORTS" tag -f "$PKG-$TAGV" "$PMBRANCH" >/dev/null
	say "applied. pmaports branch $PMBRANCH and kernel branch $NEWBR updated; tagged $PKG-$TAGV and wormdingler-camera/$TAGV. Next: --build"
	exit 0
fi

# ---------------------------------------------------------------- 5. build
APORT=$PMAPORTS/$KPKG
REPODEST=$(sed -n 's/^REPODEST=//p' ~/.abuild/abuild.conf); [ -n "$REPODEST" ] || die "REPODEST not set in ~/.abuild/abuild.conf"
VER=$(apkvar "$PMBRANCH" pkgver); REL=$(apkvar "$PMBRANCH" pkgrel)
APK=$REPODEST/$(basename "$(dirname "$KPKG")")/aarch64/$PKG-$VER-r$REL.apk
if [ "$MODE" = build ]; then
	say "building $PKG-$VER-r$REL with abuild -d (long)"
	git -C "$PMAPORTS" checkout -q "$PMBRANCH"
	(cd "$APORT" && abuild -d) || die "abuild failed"
	ls -la "$APK"; say "built. Next: --test"; exit 0
fi

# ---------------------------------------------------------------- 6. test on p4
if [ "$MODE" = test ]; then
	[ -f "$APK" ] || die "no built apk at $APK (run --build)"
	say "making a depthcharge kpart from $(basename "$APK")"
	T=$(mktemp -d "$CODE/.refresh-apk.XXXXXX"); tar -xzf "$APK" -C "$T" 2>/dev/null || true
	REL_STR=$(ls "$T/lib/modules")
	echo "kernel release in package: $REL_STR"
	sudo rm -rf "/lib/modules/$REL_STR"; sudo cp -a "$T/lib/modules/$REL_STR" /lib/modules/; sudo depmod "$REL_STR"
	W=$CODE/out/$REL_STR; rm -rf "$W/work"; mkdir -p "$W/work/dtbs"
	cp "$T/boot/vmlinuz"* "$W/work/vmlinuz"; cp "$T"/boot/dtbs/qcom/sc7180-trogdor-wormdingler-*.dtb "$W/work/dtbs/"
	KREL=/usr/share/kernel/${PKG#linux-}/kernel.release
	sudo cp "$KREL" "$KREL.stock"; echo "$REL_STR" | sudo tee "$KREL" >/dev/null
	sudo env PATH="$CODE/trogdor-support/scripts/fake-boot-deploy:$PATH" mkinitfs -d "$W/work"; sudo mv -f "$KREL.stock" "$KREL"
	. /usr/share/deviceinfo/deviceinfo
	BOOT_UUID=$(awk '$2=="/boot"{print $1}' /etc/fstab | sed 's/^UUID=//'); ROOT_UUID=$(awk '$1=="root"{print $2}' /etc/crypttab | sed 's/^UUID=//')
	CMDLINE="$(generate-kernel-cmdline 2>/dev/null) pmos_boot_uuid=$BOOT_UUID pmos_root_uuid=$ROOT_UUID pmos_rootfsopts=$(awk '$2=="/"{print $4}' /etc/fstab)"
	depthchargectl build --root none --board qc7180 --kernel "$W/work/vmlinuz" --kernel-cmdline "$CMDLINE" \
		--initramfs "$W/work/initramfs" --fdtdir "$W/work/dtbs" --compress "${deviceinfo_depthcharge_compression:-none}" --output "$W/vmlinuz.kpart" >/dev/null
	rm -rf "$T"
	say "flashing $W/vmlinuz.kpart to $TESTSLOT as UNPROVEN (one try, not successful)"
	sudo dd if="$W/vmlinuz.kpart" of="$TESTSLOT" bs=1M conv=fsync status=none
	sudo cgpt add -i 4 -P 15 -T 1 -S 0 "$DISK"; sudo cgpt show -i 4 "$DISK" | grep Attr
	cat <<EOF

Now: sudo systemctl reboot
  - good boot: desktop appears, run 'sudo kernel-keep' within 5 min, check 'cam -l' and /boot/camtest
  - bad boot: kernel-deadman reboots to the failsafe (p1) by itself; read /boot/livelog
Then: kernel-refresh.sh --install
EOF
	exit 0
fi

# ---------------------------------------------------------------- 7. install
if [ "$MODE" = install ]; then
	[ -f "$APK" ] || die "no built apk at $APK"
	say "installing $(basename "$APK") (apk pins it by checksum; boot-deploy rewrites p1)"
	sudo apk add --allow-untrusted "$APK"
	grep -n "^$PKG" /etc/apk/world
	say "syncing the bootstrap repo"
	(cd "$HERE" && ./sync.sh && ./check.sh) || true
	git -C "$HERE" status --short | head
	echo "Next: review 'git -C $HERE diff', commit there as Jesse, update ~/code/INDEX.md (1.3/1.4 kernel version)."
fi
