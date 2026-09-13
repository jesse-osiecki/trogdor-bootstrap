#!/bin/sh
# Pull the current state of the sources INTO this repo, so nothing is copied by
# hand. Afterwards `git status` shows what moved; review, then commit.
#   - manifest.txt files: copied from the live system into files/
#   - patches/kernel:     pmaports branch export (package dir + format-patch)
#   - patches/howdy:      format-patch of the pmos-pipewire branch
#   - patches/qmlkonsole: the aport directory
#   - apks/:              built packages named in group_vars (not in git)
#   - files/etc/apk/world.snapshot: reference package list
set -eu
cd "$(dirname "$0")"
CODE=${CODE:-$HOME/code}
PMAPORTS=${PMAPORTS:-$CODE/pmaports}; PMAPORTS_BRANCH=wormdingler-camera; PMAPORTS_BASE=origin/main
KPKG=device/community/linux-postmarketos-qcom-sc7180
HOWDY=${HOWDY:-$CODE/howdy}; HOWDY_BRANCH=pmos-pipewire; HOWDY_BASE=origin/master
QMLK=${QMLK:-$CODE/qmlkonsole-fix}

say() { printf '==> %s\n' "$*"; }

say "manifest files -> files/"
grep -vE '^\s*(#|$)' manifest.txt | while read -r role mode path; do
	src=$(printf '%s' "$path" | sed "s|^~|$HOME|")
	dst="files$(printf %s "$path" | sed "s|^~|/HOME|")"
	if [ -r "$src" ]; then
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
	elif [ -f "$dst" ]; then
		echo "   absent on system, repo copy kept: $path"
	else
		echo "   MISSING everywhere: $path" >&2
	fi
done
cp /etc/apk/world files/etc/apk/world.snapshot 2>/dev/null || true

say "kernel: $PMAPORTS $PMAPORTS_BRANCH"
if git -C "$PMAPORTS" rev-parse -q --verify "$PMAPORTS_BRANCH" >/dev/null; then
	rm -rf patches/kernel/linux-postmarketos-qcom-sc7180 patches/kernel/pmaports
	mkdir -p patches/kernel/linux-postmarketos-qcom-sc7180 patches/kernel/pmaports
	git -C "$PMAPORTS" archive "$PMAPORTS_BRANCH" "$KPKG" | tar -x --strip-components=3 -C patches/kernel/linux-postmarketos-qcom-sc7180
	git -C "$PMAPORTS" format-patch -q -o "$PWD/patches/kernel/pmaports" "$PMAPORTS_BASE..$PMAPORTS_BRANCH"
	git -C "$PMAPORTS" rev-parse "$PMAPORTS_BASE" > patches/kernel/BASE
	echo "   $(ls patches/kernel/linux-postmarketos-qcom-sc7180/*.patch | wc -l) kernel patches, pmaports base $(cut -c1-9 patches/kernel/BASE)"
else
	echo "   branch not found, skipped" >&2
fi

say "howdy: $HOWDY $HOWDY_BRANCH"
if git -C "$HOWDY" rev-parse -q --verify "$HOWDY_BRANCH" >/dev/null; then
	rm -f patches/howdy/*.patch
	git -C "$HOWDY" format-patch -q -o "$PWD/patches/howdy" "$HOWDY_BASE..$HOWDY_BRANCH"
	git -C "$HOWDY" rev-parse "$HOWDY_BASE" > patches/howdy/BASE
	echo "   $(ls patches/howdy/*.patch | wc -l) patch(es) on $(cut -c1-9 patches/howdy/BASE)"
else
	echo "   branch not found, skipped" >&2
fi

say "qmlkonsole: $QMLK/aport/qmlkonsole"
if [ -d "$QMLK/aport/qmlkonsole" ]; then
	rm -rf patches/qmlkonsole && mkdir -p patches/qmlkonsole
	cp "$QMLK"/aport/qmlkonsole/APKBUILD "$QMLK"/aport/qmlkonsole/*.patch patches/qmlkonsole/
	echo "   pkgrel $(grep ^pkgrel= patches/qmlkonsole/APKBUILD)"
fi

say "apks -> apks/ (gitignored)"
mkdir -p apks
for f in $(find "$QMLK/packages" -name '*.apk' 2>/dev/null); do
	cp -u "$f" apks/
done
ls apks/*.apk 2>/dev/null | sed 's|^|   |' || true

say "done; review with: git status && git diff"
