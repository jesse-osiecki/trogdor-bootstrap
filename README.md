# trogdor-bootstrap

Rebuilds a working Lenovo IdeaPad Duet 3 (google-trogdor wormdingler, postmarketOS v26.06)
from a fresh install, and keeps the patched packages current. *What* was done and why:
`~/code/INDEX.md`. *How*: this repo.

## Fresh device: 4 commands, about 20 minutes

```sh
apk add git
git clone https://github.com/jesse-osiecki/trogdor-bootstrap ~/code/trogdor-bootstrap
cd ~/code/trogdor-bootstrap
./bootstrap.sh --check --diff     # dry run: shows what would change, writes inventory/ from the examples
```

Then run `./bootstrap.sh` for real. First run installs bash and ansible-core, then applies
`site.yml` locally. Re-running is always safe (idempotent). Needs sudo.

Next: switch on the optional roles you want in `inventory/host_vars/<hostname>.yml`
(`enable_dev: true`, ...) and run `./bootstrap.sh` again.

## Roles

| Role | Default | Does |
|---|---|---|
| `base` | on | bash, keyd touchpad fix, LED sleep hook, auto-rotation udev rule, zram, libcamera tuning, local apks (camera kernel, patched qmlkonsole, kscreenlocker, plasma-mobile) |
| `dev` | off | toolchain, pipx tools, git identity, abuild key, kernel test slot units (dead-man switch, self-test) |
| `unattended` | off | **insecure**: passwordless sudo, lock screen off, LUKS keyfile in the initramfs. Enrol the key with `LUKS_PASSPHRASE=... ./bootstrap.sh --tags unattended` |
| `face_unlock` | off | Howdy from source with the PipeWire backend, config, PAM hook, enrolment launcher |

One-off values a new unit needs: keyd keyboard hash (`sudo keyd monitor -t`), PipeWire camera
node (`wpctl status`). Put them in `host_vars`. Never commit: abuild private key, LUKS keyfile,
`/etc/howdy/models/*`, Claude credentials.

Done by hand on purpose: eMMC repartition for the p4 test slot (destructive,
`~/code/trogdor-support/scripts/make-kernel-b-partition.sh`), face enrolment
(`sudo howdy add <label>`), and the kernel package build (see below).

## When an upstream moves: refresh the patch sets

Run `scripts/patch-refresh.sh all`. It prints, per project, our version vs upstream and stops.
Projects: `kernel`, `qmlkonsole`, `kscreenlocker`, `plasma-mobile`, `howdy`.

When one reports a newer upstream:

1. `scripts/patch-refresh.sh <project> --dry-run` (rebases on throw-away branches, shows the aport diff; ~5 min, kernel ~10 with the tarball download)
2. `scripts/patch-refresh.sh <project> --apply` (rebases for real, regenerates the aport, commits or syncs, tags)
3. `scripts/patch-refresh.sh <project> --build` (abuild; kernel about 2 h on the tablet)
4. `scripts/patch-refresh.sh <project> --test` (kernel: flashes the unproven p4 slot; you reboot, `kernel-deadman` falls back by itself, `sudo kernel-keep` if the desktop and cameras work)
5. `scripts/patch-refresh.sh <project> --install` (apk pins by checksum, then `sync.sh` + `check.sh`)

Works from a fresh clone of this repo: the working trees it needs (pmaports, Alpine aports,
the stable kernel, the KDE qmlkonsole clone, howdy) are cloned under `~/code` (or `$CODE`) when
missing, and the patch branches are rebuilt from the patch files this repo carries
(`patches/`, `aports/`). Needs `git`, `abuild` (the `dev` role) and network.

It stops on a rebase conflict, a patch that no longer applies, or a failed build, and tells you
where the worktree is. Patches that upstream already merged are skipped by subject match;
`refresh/<project>.skip` lists patches to drop on purpose. Configs and keys: `refresh/README.md`.
`scripts/kernel-refresh.sh` is an alias for `patch-refresh.sh kernel`.

Where the patches live:

| Project | Patches | Upstream followed |
|---|---|---|
| kernel | branch `wormdingler-camera-<ver>` in `~/code/linux` (camera series + EC charge limit, see `patches/kernel/README.md`) | pmaports `origin/main` + stable tag |
| qmlkonsole | branch `fix/stale-framebuffer` in `~/code/qmlkonsole-fix/qmlkonsole` + 2 loose patches | Alpine aports `3.24-stable` + KDE tag |
| kscreenlocker, plasma-mobile | patch files in `*-fix/aport/` | pmaports `origin/v26.06`, Alpine `3.24-stable` |
| howdy | branch `pmos-pipewire` in `~/code/howdy`, exported to `patches/howdy/` | GitHub master |

Tags: `wormdingler-camera/<ver>-r<rel>` (linux) and `linux-postmarketos-qcom-sc7180-<ver>-r<rel>`
(pmaports) per kernel package; `pmos-vXX.YY` on this repo per postmarketOS release.

## Keeping the repo and the device in sync

Rule: edit in the working tree or in this repo, apply with `bootstrap.sh`, never hand-copy.

1. Changed a patch branch or a system file: `./sync.sh`, review `git diff`, commit.
2. Does the tablet still match the repo: `./check.sh` (files, line edits, `apk audit`; `--ansible` adds a full `--check --diff`).
3. New whole file: add its path to `manifest.txt` under its role, run `./sync.sh`.
4. Value that differs per device: default in `group_vars/all.yml` + a template.
5. Package-owned file (like `/etc/keyd/default.conf`): a `lineinfile` task, never a copy, so apk upgrades don't fight it.

## Layout

```
manifest.txt        whole files managed verbatim: <role> <mode> <path>
files/              mirror of those paths, pulled from the live system by sync.sh (~ -> files/HOME/)
patches/kernel/     pmaports package dir from branch wormdingler-camera (+ BASE commit); README.md maps patches to topics and explains the rebase
patches/howdy/      format-patch of ~/code/howdy branch pmos-pipewire (+ BASE commit)
patches/qmlkonsole/ the aport (APKBUILD + patches) from ~/code/qmlkonsole-fix
aports/             APKBUILD + patch for plasma-mobile and kscreenlocker
apks/               built packages (gitignored; copy from a build host or rebuild)
refresh/            one config per patched project for patch-refresh.sh
roles/*/templates/  files with device-specific values
group_vars/all.yml  every parameter with its default; host_vars overrides per device
inventory/          *.example only; real hosts.yml and host_vars are gitignored
scripts/            patch-refresh.sh, kernel-refresh.sh, lib-kernel-test.sh, build-howdy.sh
docs/               PLASMA-6.8-MIGRATION.md: runbook for moving face unlock to Plasma 6.8's native slot
```

## Building the kernel package by hand

`patches/kernel/linux-postmarketos-qcom-sc7180/` is the full pmaports package directory
(APKBUILD, config, 30 patches: 5 upstream pmOS, 17 camera, 6 already-upstream cci fixes, 2 EC charge limit;
see `patches/kernel/README.md`), taken at the commit in `BASE`.

1. In a pmaports checkout at that commit, copy the directory over `device/community/linux-postmarketos-qcom-sc7180`.
2. `cd` into it, `abuild checksum && abuild -d` (abuild gotchas: `~/code/INDEX.md` 1.4).
3. Drop the apk in `apks/`.

When the camera series lands upstream this shrinks to the config change and the refresh flow retires.
