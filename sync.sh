#!/bin/sh
# Pull the current state of the sources INTO this repo, so nothing is copied by
# hand. Afterwards `git status` shows what moved; review, then commit.
#   - manifest.txt files: copied from the live system into files/
#   - patches/kernel:     the pmaports package directory from the camera branch (+ BASE)
#   - patches/howdy:      format-patch of the pmos-pipewire branch
#   - apks/:              built packages from abuild's REPODEST (not in git)
# The kernel and howdy branches live in clones under $CODE (default ~/code) that
# scripts/patch-refresh.sh creates; missing clones are skipped. The other aports
# (aports/, patches/qmlkonsole) are edited and built in this repo directly.
set -eu
cd "$(dirname "$0")"
CODE=${CODE:-$HOME/code}
PMAPORTS=${PMAPORTS:-$CODE/pmaports}; PMAPORTS_BRANCH=wormdingler-camera; PMAPORTS_BASE=origin/main
KPKG=device/community/linux-postmarketos-qcom-sc7180
HOWDY=${HOWDY:-$CODE/howdy}; HOWDY_BRANCH=pmos-pipewire; HOWDY_BASE=origin/master
REPODEST=${REPODEST:-$(sed -n 's/^REPODEST=//p' "$HOME/.abuild/abuild.conf" 2>/dev/null)}

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

say "kernel: $PMAPORTS $PMAPORTS_BRANCH"
if git -C "$PMAPORTS" rev-parse -q --verify "$PMAPORTS_BRANCH" >/dev/null; then
	rm -rf patches/kernel/linux-postmarketos-qcom-sc7180
	mkdir -p patches/kernel/linux-postmarketos-qcom-sc7180
	git -C "$PMAPORTS" archive "$PMAPORTS_BRANCH" "$KPKG" | tar -x --strip-components=3 -C patches/kernel/linux-postmarketos-qcom-sc7180
	git -C "$PMAPORTS" merge-base "$PMAPORTS_BASE" "$PMAPORTS_BRANCH" > patches/kernel/BASE   # the pmaports commit our branch sits on, not the tip
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

say "apks: ${REPODEST:-<no REPODEST in ~/.abuild/abuild.conf>} -> apks/ (gitignored)"
mkdir -p apks
for f in $( [ -n "$REPODEST" ] && find "$REPODEST" -name '*.apk' 2>/dev/null); do
	cp -u "$f" apks/
done
ls apks/*.apk 2>/dev/null | sed 's|^|   |' || true

say "done; review with: git status && git diff"
