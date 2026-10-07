# refresh/: one config per locally patched package

`scripts/patch-refresh.sh <project> [--dry-run|--apply|--build|--test|--install]` reads
`refresh/<project>.conf` (a shell fragment) and carries that project's patches to the
newest upstream release. `patch-refresh.sh all` runs the check for every project.
`refresh/<project>.skip` (optional) lists commit subjects to drop on rebase.

| Key | Meaning |
|---|---|
| `KIND` | `aport` (default) or `source` (no package; build with `BUILD_CMD`) |
| `PKG`, `DESC` | package name; one-line purpose used in commit messages |
| `UP_REPO`, `UP_TRACK`, `UP_PATH` | git clone holding the upstream aport, the ref we follow, the aport path |
| `OUR_BRANCH` | our aport is a branch of `UP_REPO` (kernel) ... |
| `OUR_DIR` | ... or a plain directory in this repo (`aports/<pkg>`, `patches/qmlkonsole`), regenerated and built in place |
| `PATCH_MODE` | `branch`: rebase a git branch and re-export; `files`: keep the patch files and validate them |
| `SRC_REPO`, `SRC_BRANCH`, `SRC_BRANCH_FMT`, `SRC_BASE`, `SRC_TAG_FMT` | the source clone, our patch branch (fixed name or `%s`=version), what counts as upstream, the tag naming |
| `SKIP_IN_UPSTREAM` | drop commits whose subject already exists between the old and new tag |
| `EXTRA_PATCHES` | loose patch files in our aport to keep alongside the exported ones |
| `CONFIG_FRAGMENT`, `INSERT_ANCHOR` | kernel: config additions; where patch names go in `source=` |
| `APKBUILD_PREPARE_EXTRA` | kernel: lines appended to `prepare()` of the regenerated APKBUILD (the per-build `LOCALVERSION=-r$pkgrel`) |
| `VALIDATE_PREPARE` | run `abuild fetch unpack prepare` to prove the patches apply |
| `TEST` | `kernel-p4`, `none`, or a shell command |
| `INSTALL_EXTRA` | subpackages to install with the main apk (e.g. `qmlkonsole-lang`) |
| `TAG_SRC_FMT`, `TAG_APORT` | tags created on `--apply` (kernel: `wormdingler-camera/<ver>-r<rel>`, `<pkg>-<ver>-r<rel>`) |
| `EXPORT_DIR`, `BUILD_CMD`, `INSTALL_CMD` | source kind: where patches go, how to build/install |
| `UP_URL`, `UP_CLONE_ARGS`, `UP_SPARSE` | how to clone the upstream aport repo when `UP_REPO` is missing (sparse dirs for Alpine aports) |
| `SRC_URL`, `SRC_CLONE_ARGS` | how to clone the source repo when `SRC_REPO` is missing (`%s` = the tag we are on) |
| `REPO_PATCHES` | kernel: the copy of the pmaports package dir in this repo, used to recreate `OUR_BRANCH` and the patch branch in a fresh clone |

Upstream clones, all under `$CODE` (default `~/code`), cloned on first use:

| Clone | From | Used by |
|---|---|---|
| `$CODE/pmaports` | postmarketOS pmaports (blobless) | kernel (branch `wormdingler-camera` holds our aport), kscreenlocker |
| `$CODE/aports` | Alpine aports, sparse shallow `3.24-stable` | qmlkonsole, plasma-mobile |
| `$CODE/linux` | stable kernel (shallow at our tag) | kernel (branch `wormdingler-camera-<ver>` holds our commits) |
| `$CODE/qmlkonsole` | KDE invent | qmlkonsole (branch `fix/stale-framebuffer`) |
| `$CODE/howdy` | GitHub | howdy (branch `pmos-pipewire`) |

Missing patch branches are rebuilt from the patch files in this repo, so a fresh clone
plus network is enough. Alpine's web hosts may be unreachable from a device while git
works; the script only uses git.

Kernel specifics (patch topics, what `--apply` does step by step, manual rebase): `patches/kernel/README.md`.
