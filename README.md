# trogdor-bootstrap

Reproduces a working Lenovo IdeaPad Duet 3 setup (google-trogdor wormdingler, postmarketOS
v26.06) on any trogdor device, and keeps that setup in sync with the working
trees where the patches are developed. The inventory of *what* was done and why is
`~/code/INDEX.md`; this repo is the *how*.

## Quick start on a fresh install

```sh
apk add git          # the only thing you need by hand
git clone <this repo> ~/code/trogdor-bootstrap
cd ~/code/trogdor-bootstrap
./bootstrap.sh --check --diff   # dry run first: what would change (also writes the per-device
                                # inventory files from inventory/*.example, gitignored)
./bootstrap.sh                  # installs bash + ansible-core on first run, then applies site.yml
```

`bootstrap.sh` is POSIX sh so it runs under busybox ash. It uses sudo, asking for the
password unless sudo is passwordless. Everything else is Ansible, run locally and idempotent,
so re-running is always safe. It needs only `ansible-core` (no collections).

## Roles

| Role | On by default | What it does |
|---|---|---|
| `base` | yes | bash, keyd touchpad fix (line edit), LED sleep hook, accelerometer udev rule (auto-rotation), zram tuning, libcamera tuning files, local apks (camera kernel, patched qmlkonsole) |
| `dev` | no | kernel/packaging toolchain, pipx tools, git identity, abuild key + config, test-kernel dead-man switch and telemetry units |
| `unattended` | no | **insecure**: passwordless sudo, lock screen off, LUKS keyfile in the initramfs (`LUKS_PASSPHRASE=... ./bootstrap.sh --tags unattended` to enrol the key) |
| `face_unlock` | no | Howdy built from source with the PipeWire backend, config, PAM hook, enrollment launcher |

Switch roles on per device in `inventory/host_vars/<hostname>.yml` (`enable_dev: true` etc.;
gitignored, created from `example.yml` on the first run, and the place for personal values
such as the git identity) or for one run with `-e enable_face_unlock=true`. Select roles with `--tags`.

Not automated on purpose: the eMMC repartition for the p4 test-kernel slot
(`~/code/trogdor-support/scripts/make-kernel-b-partition.sh`, destructive), building the kernel
package (two hours; the built apk goes in `apks/`), face enrollment (`sudo howdy add <label>`),
and the Claude Code auto-resume entry (session-specific).

## Where things come from

```
manifest.txt        whole files managed verbatim: <role> <mode> <path>
files/              mirror of those paths, pulled from the live system by sync.sh
                    (~ in the manifest becomes files/HOME/, owned by device_user on the device)
patches/kernel/     pmaports package dir from branch wormdingler-camera (+ BASE commit)
patches/howdy/      format-patch of ~/code/howdy branch pmos-pipewire (+ BASE commit)
patches/qmlkonsole/ the aport (APKBUILD + patches) from ~/code/qmlkonsole-fix
apks/               built packages (gitignored; copy from a build host or rebuild)
roles/*/templates/  files with device-specific values (howdy config, sudoers, launcher)
group_vars/all.yml  every parameter with its default; host_vars overrides per device
inventory/          *.example only; the real hosts.yml and host_vars are gitignored
scripts/            build-howdy.sh (called by the role)
```

## Keeping it current

The rule: edit in the working tree or in this repo, apply with `bootstrap.sh`, never hand-copy.

- After changing a patch branch or a system file: `./sync.sh`, then `git diff` shows exactly what
  moved. Commit it.
- To see whether the tablet still matches the repo: `./check.sh` (files, line edits, `apk audit`,
  unmanaged files in the directories we own; the audit is complete only with passwordless sudo). `./check.sh --ansible` adds a full
  `ansible-playbook --check --diff`, which also covers templates, packages and units.
- Adding a new whole file: put its path in `manifest.txt` under the right role, run `./sync.sh`.
  Adding a value that differs between devices: `group_vars/all.yml` default + template.
- Editing a package-owned file (like `/etc/keyd/default.conf`): a `lineinfile` task, never a copy,
  so apk upgrades don't fight it.

Device-specific values you will need for a new unit: the keyd keyboard hash
(`sudo keyd monitor -t`) and the PipeWire camera node (`wpctl status`). Never commit: the abuild
private key, the LUKS keyfile, `/etc/howdy/models/*`, Claude credentials.

## Kernel

`patches/kernel/linux-postmarketos-qcom-sc7180/` is the complete pmaports package directory
(APKBUILD, config, 28 patches of which 23 come from branch `wormdingler-camera`), taken from a
pmaports checkout at the commit in `BASE`. To rebuild on a device with the `dev` role: copy the
directory over `device/community/linux-postmarketos-qcom-sc7180` in a pmaports checkout at that
commit, `cd` into it,
`abuild checksum && abuild -d` (see `~/code/INDEX.md` 1.4 for the abuild gotchas), then drop the
apk in `apks/`. When the camera series lands upstream, this shrinks to the config change.
