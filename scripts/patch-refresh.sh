#!/bin/sh
# patch-refresh.sh: carry a local patch set to a newer upstream release, one
# guarded stage at a time. One driver, one config per project in ../refresh/.
#
#   patch-refresh.sh <project>              check: compare our build with upstream
#   patch-refresh.sh <project> --dry-run    + rebase on throw-away branches, regenerate
#                                           the aport in a scratch copy, show the diff
#   patch-refresh.sh <project> --apply      rebase for real, regenerate, commit/sync
#   patch-refresh.sh <project> --build      build (abuild -d, or the project's builder)
#   patch-refresh.sh <project> --test       project-specific test (kernel: kpart to p4)
#   patch-refresh.sh <project> --install    install (apk pins by checksum) and sync
#   patch-refresh.sh all                    check every project
#
# Options: --version X.Y.Z (target upstream version), --force (run with no upstream change).
#
# Projects: kernel (pmaports aport, patch branch in $CODE/linux), qmlkonsole (Alpine
# aport in patches/qmlkonsole, patch branch in the KDE clone + loose patch files),
# kscreenlocker and plasma-mobile (aports/<pkg>, patch files only, validated with
# abuild prepare), howdy (source build, patch branch rebased onto upstream master).
# Upstream clones live under $CODE (default ~/code) and are cloned on first use.
#
# The script stops at anything that needs a human: a rebase conflict, a patch that
# no longer applies, a failed build, and always before a reboot or an install.
# Commits use the git identity of this repo (git config user.name/user.email).
# Config keys are documented in refresh/README.md.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
CODE=${CODE:-$HOME/code}
AUTHOR_NAME=$(git -C "$HERE" config user.name || true); AUTHOR_EMAIL=$(git -C "$HERE" config user.email || true)

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit "${2:-1}"; }
have() { git -C "$1" rev-parse -q --verify "$2" >/dev/null 2>&1; }
# Throw-away worktrees/branches/dirs registered in CLEANUP ("src:<repo>:<dir>:<ref>" etc.) are
# removed on any exit of a dry run, so a failure never leaves clutter behind.
CLEANUP=""
run_cleanup() {
	for c in $CLEANUP; do
		kind=${c%%:*}; rest=${c#*:}
		case "$kind" in
		wt) repo=${rest%%:*}; rest=${rest#*:}; dir=${rest%%:*}; ref=${rest#*:}
		    git -C "$repo" rebase --abort >/dev/null 2>&1 || true
		    git -C "$repo" worktree remove --force "$dir" >/dev/null 2>&1 || true
		    git -C "$repo" branch -q -D "$ref" >/dev/null 2>&1 || true;;
		dir) rm -rf "$rest";;
		esac
	done
	CLEANUP=""
}
# Evaluate pkgver/pkgrel of an APKBUILD text on stdin (handles pkgver=9999$_pkgver).
apkvars() { env -i HOME="$HOME" sh -c 'eval "$(cat)" 2>/dev/null; printf "%s %s\n" "$pkgver" "$pkgrel"'; }

[ $# -ge 1 ] || { sed -n '2,24p' "$0"; exit 64; }
PROJECT=$1; shift
if [ "$PROJECT" = all ]; then
	rc=0
	for c in "$HERE"/refresh/*.conf; do
		"$0" "$(basename "$c" .conf)" "$@" || rc=$?
	done
	exit $rc
fi
CONF=$HERE/refresh/$PROJECT.conf
[ -f "$CONF" ] || die "no config $CONF"

MODE=check; FORCE=0; WANTVER=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) MODE=dryrun;; --apply) MODE=apply;; --build) MODE=build;;
	--test) MODE=test;; --install) MODE=install;; --force) FORCE=1;;
	--version|--kernel-version) WANTVER=$2; shift;;
	-h|--help) sed -n '2,24p' "$0"; exit 0;;
	*) die "unknown option $1" 64;;
	esac; shift
done

# ---- defaults, then the project config -------------------------------------------------
KIND=aport; PKG=; DESC=; UP_REPO=; UP_TRACK=; UP_PATH=; OUR_BRANCH=; OUR_DIR=
PATCH_MODE=files; SRC_REPO=; SRC_BRANCH=; SRC_BRANCH_FMT=; SRC_BASE=; SRC_TAG_FMT='v%s'
SKIP_IN_UPSTREAM=0; EXTRA_PATCHES=; CONFIG_FRAGMENT=; INSERT_ANCHOR=; VALIDATE_PREPARE=0; APKBUILD_PREPARE_EXTRA=
TEST=none; INSTALL_EXTRA=; TAG_SRC_FMT=; TAG_APORT=0; EXPORT_DIR=; BUILD_CMD=; INSTALL_CMD=
UP_URL=; UP_CLONE_ARGS=; UP_SPARSE=; SRC_URL=; SRC_CLONE_ARGS=; REPO_PATCHES=
. "$CONF"
[ -n "$PKG" ] || die "PKG not set in $CONF"
[ "$MODE" = dryrun ] && trap run_cleanup EXIT
gitj() {   # git with the repo's identity as author and committer
	[ -n "$AUTHOR_NAME" ] && [ -n "$AUTHOR_EMAIL" ] || die "set git config user.name and user.email in $HERE (commits are made in that name)"
	git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" "$@"
}

# A fresh clone of this repo has no working trees under $CODE: create them on demand.
ensure_repo() {  # dir url [clone args...]
	[ -d "$1/.git" ] && return 0
	d=$1; u=$2; shift 2
	[ -n "$u" ] || die "$d is missing and no clone URL is configured"
	say "cloning $u -> $d"; git clone -q "$@" "$u" "$d"
}
# Our patches as an ordered list of files: everything in our aport copy that upstream's
# aport (at the base commit) does not have, minus the loose EXTRA_PATCHES.
our_branch_patches() {  # aportdir upstream_ref
	up=$(git -C "$UP_REPO" ls-tree --name-only "$2" "$UP_PATH/" 2>/dev/null | sed 's|.*/||')
	for f in "$1"/*.patch; do
		b=$(basename "$f"); echo "$up" | grep -Fxq "$b" && continue
		echo " $EXTRA_PATCHES " | grep -Fq " $b " && continue
		echo "$f"
	done
}
rebuild_branch() {  # repo branch base patchfiles...
	r=$1; br=$2; base=$3; shift 3
	say "rebuilding patch branch $br in $r from $# patch file(s) on $base"
	W=$(mktemp -d "$CODE/.refresh-rebuild.XXXXXX")
	git -C "$r" worktree add -q -b "$br" "$W" "$base"
	if ! gitj -C "$W" am -q "$@"; then
		git -C "$W" am --abort >/dev/null 2>&1 || true
		git -C "$r" worktree remove --force "$W" >/dev/null 2>&1 || true; git -C "$r" branch -q -D "$br" >/dev/null 2>&1 || true
		die "patches do not apply on $base; the repo copy is inconsistent"
	fi
	git -C "$r" worktree remove --force "$W"
}
SKIPLIST=$HERE/refresh/$PROJECT.skip

# =============================================================== source-build projects
if [ "$KIND" = source ]; then
	ensure_repo "$SRC_REPO" "$SRC_URL"
	if ! have "$SRC_REPO" "$SRC_BRANCH"; then
		base=$(cat "$EXPORT_DIR/BASE"); have "$SRC_REPO" "$base" || git -C "$SRC_REPO" fetch -q origin "$base"
		rebuild_branch "$SRC_REPO" "$SRC_BRANCH" "$base" "$EXPORT_DIR"/*.patch
	fi
	say "$PROJECT: fetching $SRC_REPO ($SRC_BASE)"
	git -C "$SRC_REPO" fetch -q origin 2>/dev/null || echo "warning: fetch failed (upstream host busy?); using the cached $SRC_BASE"
	BASE_NOW=$(git -C "$SRC_REPO" rev-parse "$SRC_BASE"); BASE_REC=$(cat "$EXPORT_DIR/BASE" 2>/dev/null || echo none)
	N=$(git -C "$SRC_REPO" rev-list --count "$SRC_BASE..$SRC_BRANCH")
	echo "upstream $SRC_BASE: $(git -C "$SRC_REPO" log -1 --format='%h %s' "$SRC_BASE" | cut -c1-70)"
	echo "our branch $SRC_BRANCH: $N commit(s); patches exported on top of $(echo "$BASE_REC" | cut -c1-9)"
	if [ "$BASE_NOW" = "$BASE_REC" ] && [ "$FORCE" = 0 ] && [ "$MODE" != build ] && [ "$MODE" != install ]; then
		echo "nothing new: upstream unchanged since the exported patches"; exit 0
	fi
	case "$MODE" in
	check) exit 0;;
	dryrun|apply)
		say "rebasing $SRC_BRANCH onto $SRC_BASE"
		W=$(mktemp -d "$CODE/.refresh-$PROJECT.XXXXXX"); REF=refresh-dryrun
		[ "$MODE" = apply ] && REF=$SRC_BRANCH-rebased
		git -C "$SRC_REPO" worktree add -q -B "$REF" "$W" "$SRC_BRANCH"; [ "$MODE" = dryrun ] && CLEANUP="wt:$SRC_REPO:$W:$REF"
		if ! git -C "$W" rebase -q "$SRC_BASE" >/dev/null 2>&1; then
			echo "  conflicting commit: $(git -C "$W" log -1 --format=%s REBASE_HEAD)"
			git -C "$W" diff --name-only --diff-filter=U | sed 's/^/  conflict: /'
			[ "$MODE" = apply ] && die "resolve in $W (git rebase --continue), then: git -C $SRC_REPO branch -f $SRC_BRANCH $REF; rerun --apply" 2
			git -C "$W" rebase --abort; git -C "$SRC_REPO" worktree remove --force "$W"; git -C "$SRC_REPO" branch -q -D "$REF"
			die "rebase conflicts (dry run, nothing kept)" 2
		fi
		echo "rebase clean: $(git -C "$W" rev-list --count "$SRC_BASE..$REF") commit(s) on $(git -C "$W" rev-parse --short "$SRC_BASE")"
		if [ "$MODE" = dryrun ]; then
			git -C "$W" format-patch -q --stat --summary "$SRC_BASE..$REF" -o "$W/.out" >/dev/null; ls "$W/.out" | sed 's/^/  would export: /'
			git -C "$SRC_REPO" worktree remove --force "$W"; git -C "$SRC_REPO" branch -q -D "$REF"
			say "dry run complete, nothing kept. Next: --apply"; exit 0
		fi
		git -C "$SRC_REPO" worktree remove --force "$W"
		git -C "$SRC_REPO" branch -f "$SRC_BRANCH" "$REF"; git -C "$SRC_REPO" branch -q -D "$REF"
		say "exporting patches to $EXPORT_DIR"
		rm -f "$EXPORT_DIR"/*.patch; git -C "$SRC_REPO" format-patch -q -o "$EXPORT_DIR" "$SRC_BASE..$SRC_BRANCH"
		git -C "$SRC_REPO" rev-parse "$SRC_BASE" > "$EXPORT_DIR/BASE"
		ls "$EXPORT_DIR"; git -C "$HERE" status --short -- "${EXPORT_DIR#"$HERE/"}" | head
		say "applied: branch $SRC_BRANCH moved, patches exported. Review 'git -C $HERE diff', commit. Next: --build"; exit 0;;
	build) say "building with: $BUILD_CMD"; eval "$BUILD_CMD"; exit $?;;
	test) echo "test for $PROJECT: $TEST"; exit 0;;
	install) say "installing with: ${INSTALL_CMD:-$BUILD_CMD}"; eval "${INSTALL_CMD:-$BUILD_CMD}"; (cd "$HERE" && ./sync.sh >/dev/null && ./check.sh | tail -3); exit 0;;
	esac
fi

# =============================================================== aport projects
ensure_repo "$UP_REPO" "$UP_URL" $UP_CLONE_ARGS
if [ -n "$UP_SPARSE" ] && git -C "$UP_REPO" sparse-checkout list >/dev/null 2>&1; then
	for d in $UP_SPARSE; do git -C "$UP_REPO" sparse-checkout list | grep -Fxq "$d" || git -C "$UP_REPO" sparse-checkout add "$d" >/dev/null 2>&1; done
fi
say "$PROJECT: fetching upstream aport ($UP_REPO $UP_TRACK)"
B=${UP_TRACK#origin/}
git -C "$UP_REPO" fetch -q origin "+refs/heads/$B:refs/remotes/origin/$B" 2>/dev/null \
	|| { have "$UP_REPO" "$UP_TRACK" && echo "warning: fetch failed (upstream host busy?); using the cached $UP_TRACK"; } \
	|| die "cannot fetch $UP_TRACK from $UP_REPO"
if [ -n "$OUR_BRANCH" ] && ! have "$UP_REPO" "$OUR_BRANCH"; then
	base=$(cat "$REPO_PATCHES/../BASE"); have "$UP_REPO" "$base" || git -C "$UP_REPO" fetch -q origin "$base"
	say "recreating aport branch $OUR_BRANCH from $REPO_PATCHES on $(echo "$base" | cut -c1-9)"
	W=$(mktemp -d "$CODE/.refresh-rebuild.XXXXXX"); git -C "$UP_REPO" worktree add -q -b "$OUR_BRANCH" "$W" "$base"
	rm -rf "$W/$UP_PATH"; mkdir -p "$W/$UP_PATH"; cp -a "$REPO_PATCHES/." "$W/$UP_PATH/"
	git -C "$W" add -A "$UP_PATH"; gitj -C "$W" commit -q --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" -m "$PKG: $DESC (restored from trogdor-bootstrap)"
	git -C "$UP_REPO" worktree remove --force "$W"
fi
if [ -n "$OUR_DIR" ] && [ ! -f "$OUR_DIR/APKBUILD" ]; then
	say "recreating $OUR_DIR from $REPO_PATCHES"; mkdir -p "$OUR_DIR"; cp -a "$REPO_PATCHES/." "$OUR_DIR/"
	[ -f "$REPO_PATCHES/.refresh-base" ] || git -C "$UP_REPO" rev-parse "$UP_TRACK" > "$OUR_DIR/.refresh-base"
fi
set -- $(git -C "$UP_REPO" show "$UP_TRACK:$UP_PATH/APKBUILD" | apkvars); UPVER=$1; UPREL=$2
if [ -n "$OUR_BRANCH" ]; then
	set -- $(git -C "$UP_REPO" show "$OUR_BRANCH:$UP_PATH/APKBUILD" | apkvars)
else
	set -- $(apkvars < "$OUR_DIR/APKBUILD")
fi
OURVER=$1; OURREL=$2
NEWVER=${WANTVER:-$UPVER}
echo "upstream: $PKG $UPVER-r$UPREL"
echo "ours:     $PKG $OURVER-r$OURREL $([ -n "$OUR_BRANCH" ] && echo "(branch $OUR_BRANCH)" || echo "($OUR_DIR)")"
echo "target:   $NEWVER"
apk policy "$PKG" 2>/dev/null | grep -B1 'http' | grep -vE 'http|--' | sed 's/^ *//; s/:$//; s/^/repo has: /' | head -2
BASEFILE=${OUR_DIR:+$OUR_DIR/.refresh-base}
BASEREF=$( [ -n "$OUR_BRANCH" ] && git -C "$UP_REPO" merge-base "$OUR_BRANCH" "$UP_TRACK" || cat "$BASEFILE" 2>/dev/null || echo "$UP_TRACK")
# A fresh shallow clone lacks the recorded base: fetch it by id (a lazy fetch inside git log
# would stall), then compare the aport's tree at base and upstream, which needs no history.
GIT_NO_LAZY_FETCH=1 git -C "$UP_REPO" cat-file -e "$BASEREF^{commit}" 2>/dev/null || git -C "$UP_REPO" fetch -q --depth=1 --filter=blob:none origin "$BASEREF" 2>/dev/null || true
if [ "$(GIT_NO_LAZY_FETCH=1 git -C "$UP_REPO" rev-parse -q --verify "$BASEREF:$UP_PATH" 2>/dev/null)" = "$(git -C "$UP_REPO" rev-parse "$UP_TRACK:$UP_PATH")" ]; then
	APORT_CHANGED=0
else
	APORT_CHANGED=$(GIT_NO_LAZY_FETCH=1 git -C "$UP_REPO" log --oneline "$BASEREF..$UP_TRACK" -- "$UP_PATH" 2>/dev/null | wc -l)
	[ "$APORT_CHANGED" -gt 0 ] || APORT_CHANGED="1+"   # history too shallow to count
fi
echo "upstream aport commits since our base: $APORT_CHANGED"
if [ "$NEWVER" = "$OURVER" ] && [ "$APORT_CHANGED" = 0 ] && [ "$FORCE" = 0 ] && [ "$MODE" != build ] && [ "$MODE" != test ] && [ "$MODE" != install ]; then
	echo "nothing new (use --force to regenerate anyway)"; exit 0
fi
[ "$MODE" = check ] && exit 0

# strip a 9999-style prefix so tags and branches use the real upstream version
PLAINVER=$(git -C "$UP_REPO" show "$UP_TRACK:$UP_PATH/APKBUILD" | env -i sh -c 'eval "$(cat)" 2>/dev/null; printf "%s\n" "${_pkgver:-$pkgver}"')
[ -n "$WANTVER" ] && PLAINVER=$WANTVER
[ "$NEWVER" = "$UPVER" ] && NEWREL=$((UPREL+1)) || NEWREL=1
[ "$NEWREL" -le "$OURREL" ] && [ "$NEWVER" = "$OURVER" ] && NEWREL=$((OURREL+1))

if [ "$MODE" = dryrun ] || [ "$MODE" = apply ]; then
	CLEANUP=""
	# ---- 2. our aport: a branch in the upstream repo, or a plain directory
	if [ -n "$OUR_BRANCH" ]; then
		[ -z "$(git -C "$UP_REPO" status --porcelain --untracked-files=no)" ] || die "$UP_REPO has uncommitted changes"
		say "rebasing $OUR_BRANCH onto $UP_TRACK"
		if [ "$MODE" = dryrun ]; then
			PMWORK=$(mktemp -d "$CODE/.refresh-aport.XXXXXX"); PMREF=refresh-dryrun
			git -C "$UP_REPO" worktree add -q -B "$PMREF" "$PMWORK" "$OUR_BRANCH"; CLEANUP="$CLEANUP wt:$UP_REPO:$PMWORK:$PMREF"
		else
			PMWORK=$UP_REPO; PMREF=$OUR_BRANCH; git -C "$UP_REPO" checkout -q "$OUR_BRANCH"
		fi
		if ! git -C "$PMWORK" rebase -q "$UP_TRACK" >/dev/null 2>&1; then
			git -C "$PMWORK" diff --name-only --diff-filter=U | sed 's/^/  conflict: /'; git -C "$PMWORK" rebase --abort
			die "aport branch rebase conflicts; resolve by hand in $UP_REPO" 2
		fi
		APORT=$PMWORK/$UP_PATH
	else
		if [ "$MODE" = dryrun ]; then APORT=$(mktemp -d "$CODE/.refresh-aport.XXXXXX"); CLEANUP="$CLEANUP dir:$APORT"; cp -a "$OUR_DIR/." "$APORT/"; else APORT=$OUR_DIR; fi
	fi

	# ---- 3. patches: rebase a branch onto the new tag, or keep the files
	OURPATCHES=""
	if [ "$PATCH_MODE" = branch ]; then
		NEWTAG=$(printf "$SRC_TAG_FMT" "$PLAINVER"); OLDTAG=$(printf "$SRC_TAG_FMT" "$OURVER")
		CUR=${SRC_BRANCH:-$(printf "$SRC_BRANCH_FMT" "$OURVER")}
		NEWBR=$( [ -n "$SRC_BRANCH_FMT" ] && printf "$SRC_BRANCH_FMT" "$PLAINVER" || echo "$SRC_BRANCH")
		BASE=${SRC_BASE:-$OLDTAG}
		# shellcheck disable=SC2059
		ensure_repo "$SRC_REPO" "$SRC_URL" $(printf "$SRC_CLONE_ARGS" "$OLDTAG")
		if ! have "$SRC_REPO" "$CUR"; then
			have "$SRC_REPO" "$OLDTAG" || git -C "$SRC_REPO" fetch -q origin tag "$OLDTAG"
			CURAPORT=$( [ -n "$OUR_BRANCH" ] && echo "$UP_REPO/$UP_PATH" || echo "$OUR_DIR")
			[ -n "$OUR_BRANCH" ] && git -C "$UP_REPO" checkout -q "$OUR_BRANCH"
			rebuild_branch "$SRC_REPO" "$CUR" "$OLDTAG" $(our_branch_patches "$CURAPORT" "$BASEREF")
		fi
		have "$SRC_REPO" "$CUR" || die "patch branch $CUR not found in $SRC_REPO"
		have "$SRC_REPO" "$NEWTAG" || git -C "$SRC_REPO" fetch -q origin tag "$NEWTAG" || die "tag $NEWTAG not found upstream"
		# Our commits = what CUR has beyond upstream. Upstream may be the old tag (branch rebuilt
		# from patch files) or SRC_BASE (branch developed on master): take the nearer one.
		if [ -n "$SRC_BASE" ] && have "$SRC_REPO" "$OLDTAG"; then
			n1=$(git -C "$SRC_REPO" rev-list --count "$OLDTAG..$CUR"); n2=$(git -C "$SRC_REPO" rev-list --count "$SRC_BASE..$CUR")
			[ "$n1" -le "$n2" ] && BASE=$OLDTAG || BASE=$SRC_BASE
		fi
		say "rebasing $(git -C "$SRC_REPO" rev-list --count "$BASE..$CUR") commit(s) from $CUR onto $NEWTAG"
		KWORK=$(mktemp -d "$CODE/.refresh-src.XXXXXX"); KREF=$( [ "$MODE" = dryrun ] && echo refresh-dryrun || echo "$NEWBR.refresh")
		git -C "$SRC_REPO" worktree add -q -B "$KREF" "$KWORK" "$CUR"; [ "$MODE" = dryrun ] && CLEANUP="$CLEANUP wt:$SRC_REPO:$KWORK:$KREF"
		ok=1
		if ! git -C "$KWORK" rebase -q --onto "$NEWTAG" "$(git -C "$SRC_REPO" merge-base "$BASE" "$CUR")" >/dev/null 2>&1; then
			while [ -d "$(git -C "$KWORK" rev-parse --git-path rebase-merge)" ]; do
				subj=$(git -C "$KWORK" log -1 --format=%s REBASE_HEAD)
				if [ "$SKIP_IN_UPSTREAM" = 1 ] && git -C "$SRC_REPO" log --format=%s "$OLDTAG..$NEWTAG" | grep -Fxq "$subj"; then
					echo "  already upstream, skipping: $subj"
				elif [ -f "$SKIPLIST" ] && grep -Fxq "$subj" "$SKIPLIST"; then
					echo "  on the skip list, dropping: $subj"
				else ok=0; break; fi
				git -C "$KWORK" rebase --skip >/dev/null 2>&1 && break || true
			done
		fi
		if [ "$ok" = 0 ]; then
			echo "  conflicting patch: $(git -C "$KWORK" log -1 --format=%s REBASE_HEAD)"
			git -C "$KWORK" diff --name-only --diff-filter=U | sed 's/^/  conflict: /'
			[ "$MODE" = apply ] && die "resolve in $KWORK (git rebase --continue), then rerun --apply" 2
			run_cleanup
			die "patch rebase conflicts on $NEWTAG (dry run, nothing kept)" 2
		fi
		NPATCH=$(git -C "$KWORK" rev-list --count "$NEWTAG..$KREF"); echo "rebase clean: $NPATCH patch(es) on $NEWTAG"
	fi

	# ---- 4. regenerate the aport from the pristine upstream copy
	say "regenerating the aport from $UP_TRACK"
	KEEP=$(mktemp -d "$CODE/.refresh-keep.XXXXXX")
	for f in $EXTRA_PATCHES; do cp "$APORT/$f" "$KEEP/"; done
	if [ "$PATCH_MODE" = files ]; then
		UPFILES=$(git -C "$UP_REPO" ls-tree --name-only "$UP_TRACK" "$UP_PATH/" | sed 's|.*/||')
		for f in "$APORT"/*.patch; do [ -f "$f" ] || continue; echo "$UPFILES" | grep -Fxq "$(basename "$f")" || cp "$f" "$KEEP/"; done
	fi
	[ -n "$OUR_BRANCH" ] && git -C "$PMWORK" rm -q -r --cached "$UP_PATH" >/dev/null 2>&1 || true
	rm -rf "$APORT"; mkdir -p "$APORT"
	git -C "$UP_REPO" archive "$UP_TRACK" "$UP_PATH" | tar -x --strip-components="$(echo "$UP_PATH" | tr -cd / | wc -c | xargs expr 1 +)" -C "$APORT"
	UPPATCHES=$(sed -n '/^source="/,/^"/p' "$APORT/APKBUILD" | grep -c '\.patch$' || true)
	if [ "$PATCH_MODE" = branch ]; then
		git -C "$KWORK" format-patch -q --no-signature --start-number "$((UPPATCHES+1))" -o "$APORT" "$NEWTAG..$KREF"
		OURPATCHES=$(ls "$APORT" | grep -E '^[0-9]{4}-.*\.patch$' | sort | tail -n "+$((UPPATCHES+1))")
	fi
	for f in "$KEEP"/*.patch; do [ -f "$f" ] && { cp "$f" "$APORT/"; OURPATCHES="$OURPATCHES $(basename "$f")"; }; done
	rm -rf "$KEEP"
	PREPARE_EXTRA="$APKBUILD_PREPARE_EXTRA" python3 - "$APORT/APKBUILD" "$NEWVER" "$NEWREL" "$INSERT_ANCHOR" $OURPATCHES <<'EOF'
import sys,re,os
p,ver,rel,anchor,*patches=sys.argv[1:]
s=open(p).read()
extra=os.environ.get('PREPARE_EXTRA','')
if extra and extra not in s:                            # kernel: lines appended to prepare() (per-build release string)
    m=re.search(r'^prepare\(\) \{\n(.*?)^\}', s, re.M|re.S)
    s=s[:m.end(1)]+''.join('\t%s\n'%l for l in extra.split('\\n'))+s[m.end(1):]
if not re.search(r'^pkgver=.*\$', s, re.M):           # plain version: set it; 9999$_pkgver style stays
    s=re.sub(r'^pkgver=.*$', 'pkgver=%s'%ver, s, count=1, flags=re.M)
s=re.sub(r'^pkgrel=\d+$', 'pkgrel=%s'%rel, s, count=1, flags=re.M)
m=re.search(r'^source="([^"]*)"', s, re.M|re.S)       # single- or multi-line, first closing quote
items=m.group(1).split()
if anchor and any(anchor in it for it in items):
    i=[k for k,it in enumerate(items) if anchor in it][0]
else:
    i=max(k for k,it in enumerate(items) if '://' in it)+1
items[i:i]=patches
block='source="\n'+''.join('\t%s\n'%it for it in items)+'\t"'
s=s[:m.start()]+block+s[m.end():]
open(p,'w').write(s)
EOF
	if [ -n "$CONFIG_FRAGMENT" ] && [ -s "$CONFIG_FRAGMENT" ]; then
		CFG=$APORT/$(sed -n 's/^_config="\(.*\)"/\1/p' "$APORT/APKBUILD" | sed "s/\$_flavor/${PKG#linux-}/; s/\$arch/aarch64/")
		grep -vE '^\s*(#|$)' "$CONFIG_FRAGMENT" | while read -r line; do
			name=${line%%=*}; val=${line#*=}
			case "$val" in y) "$CODE/linux/scripts/config" --file "$CFG" --enable "${name#CONFIG_}";;
			m) "$CODE/linux/scripts/config" --file "$CFG" --module "${name#CONFIG_}";;
			n) "$CODE/linux/scripts/config" --file "$CFG" --disable "${name#CONFIG_}";;
			*) "$CODE/linux/scripts/config" --file "$CFG" --set-val "${name#CONFIG_}" "$val";; esac
		done
	fi
	echo "abuild checksum (downloads the source tarball on first use)"
	(cd "$APORT" && abuild checksum >"$APORT/.checksum.log" 2>&1) || { grep -vE '^>>>' "$APORT/.checksum.log" | tail -6 | sed 's/^/  abuild: /'; die "abuild checksum failed for $NEWVER"; }
	rm -f "$APORT/.checksum.log"
	if [ "$VALIDATE_PREPARE" = 1 ]; then
		echo "abuild prepare: checking that the patches apply to $NEWVER"
		if ! (cd "$APORT" && abuild -d fetch unpack prepare >"$APORT/.prepare.log" 2>&1); then
			grep -A3 -E 'Hunk .*FAILED|failed to apply' "$APORT/.prepare.log" | grep -vE '^--$|: OK$' | head -12 | sed 's/^/  abuild: /'
			(cd "$APORT" && abuild clean >/dev/null 2>&1) || true
			WHERE=$( [ "$MODE" = dryrun ] && echo "${OUR_DIR:-$UP_REPO/$UP_PATH}" || echo "$APORT")
			die "a patch no longer applies to $NEWVER (named above). Fix it in $WHERE, then rerun" 2
		fi
		(cd "$APORT" && abuild clean >/dev/null 2>&1) || true; rm -f "$APORT/.prepare.log"
	fi
	set -- $(apkvars < "$APORT/APKBUILD"); echo "aport now: $PKG $1-r$2, $(ls "$APORT"/*.patch 2>/dev/null | wc -l) patch file(s)"

	if [ -n "$OUR_BRANCH" ]; then
		git -C "$PMWORK" add -A "$UP_PATH"
		gitj -C "$PMWORK" commit -q --author="$AUTHOR_NAME <$AUTHOR_EMAIL>" \
			-m "$PKG: $DESC ($1)" -m "Rebased the local patch set onto $1 (${NPATCH:-?} patches). Generated by trogdor-bootstrap/scripts/patch-refresh.sh." || die "nothing to commit"
		git -C "$PMWORK" show --stat --format='%h %s' HEAD | tail -3
	fi
	if [ "$MODE" = dryrun ]; then
		say "dry run: APKBUILD diff"
		if [ -n "$OUR_BRANCH" ]; then git -C "$PMWORK" diff "$OUR_BRANCH" "$PMREF" -- "$UP_PATH/APKBUILD" | grep -vE '^[-+ ][0-9a-f]{128}' | head -50
		else diff -u "$OUR_DIR/APKBUILD" "$APORT/APKBUILD" | grep -vE '^[-+ ][0-9a-f]{128}' | head -50 || true; fi
		run_cleanup
		say "dry run complete, nothing kept. Next: --apply"; exit 0
	fi
	if [ "$PATCH_MODE" = branch ]; then
		git -C "$SRC_REPO" worktree remove --force "$KWORK"
		git -C "$SRC_REPO" branch -f "$NEWBR" "$KREF"; git -C "$SRC_REPO" branch -q -D "$KREF"
		[ -n "$TAG_SRC_FMT" ] && git -C "$SRC_REPO" tag -f "$(printf "$TAG_SRC_FMT" "$1-r$2")" "$NEWBR" >/dev/null
	fi
	[ "$TAG_APORT" = 1 ] && [ -n "$OUR_BRANCH" ] && git -C "$UP_REPO" tag -f "$PKG-$1-r$2" "$OUR_BRANCH" >/dev/null
	[ -n "$BASEFILE" ] && git -C "$UP_REPO" rev-parse "$UP_TRACK" > "$BASEFILE"
	(cd "$HERE" && ./sync.sh >/dev/null 2>&1) || true
	say "applied. $( [ -n "$OUR_BRANCH" ] && echo "Committed on $OUR_BRANCH and tagged; sync.sh copied it to patches/kernel." || echo "Aport regenerated in place ($OUR_DIR).") Review 'git -C $HERE diff' and commit. Next: --build"
	exit 0
fi

# ---- 5. build / test / install --------------------------------------------------------
APORT=$( [ -n "$OUR_BRANCH" ] && echo "$UP_REPO/$UP_PATH" || echo "$OUR_DIR")
REPODEST=$(sed -n 's/^REPODEST=//p' ~/.abuild/abuild.conf); [ -n "$REPODEST" ] || die "REPODEST not set in ~/.abuild/abuild.conf"
set -- $(apkvars < "$APORT/APKBUILD"); VER=$1; REL=$2
APK=$REPODEST/$(basename "$(dirname "$APORT")")/aarch64/$PKG-$VER-r$REL.apk
case "$MODE" in
build)
	say "building $PKG-$VER-r$REL with abuild -d (kernel: about 2 h)"
	[ -n "$OUR_BRANCH" ] && git -C "$UP_REPO" checkout -q "$OUR_BRANCH"
	(cd "$APORT" && abuild -d) || die "abuild failed"
	ls -la "$APK"; say "built. Next: --test";;
test)
	[ -f "$APK" ] || die "no built apk at $APK (run --build)"
	case "$TEST" in
	kernel-p4) . "$HERE/scripts/lib-kernel-test.sh"; kernel_test_p4 "$APK";;
	none) echo "no automated test for $PROJECT; install and try it. Next: --install";;
	*) say "test: $TEST"; eval "$TEST";;
	esac;;
install)
	[ -f "$APK" ] || die "no built apk at $APK"
	EXTRA=""; for s in $INSTALL_EXTRA; do EXTRA="$EXTRA $(dirname "$APK")/$s-$VER-r$REL.apk"; done
	say "installing $(basename "$APK")$EXTRA (apk pins by checksum)"
	if [ "$TEST" = kernel-p4 ] && [ -d "/lib/modules/$VER-r$REL" ] && ! apk info -L "$PKG" 2>/dev/null | grep -q "^usr/lib/modules/$VER-r$REL/"; then
		echo "removing the modules staged by --test (/lib/modules/$VER-r$REL); the package brings the same files"
		sudo rm -rf "/lib/modules/$VER-r$REL"
	fi
	sudo apk add --allow-untrusted "$APK" $EXTRA
	grep -nE "^$PKG(><|=)" /etc/apk/world
	(cd "$HERE" && ./sync.sh >/dev/null && ./check.sh | tail -3) || true
	echo "Next: review 'git -C $HERE diff', commit, and update local_apks in group_vars/all.yml.";;
esac
