# trogdor-bootstrap

Rebuilds a working Lenovo IdeaPad Duet 3 (google-trogdor wormdingler, Qualcomm sc7180,
postmarketOS v26.06 with Plasma Mobile) from a fresh install, keeps the patched packages
current, and carries the patches that are headed upstream. Everything it needs is in
this repo; upstream source trees are cloned on demand.

## Fresh device: 4 commands, about 20 minutes

Prerequisite: postmarketOS installed with pmbootstrap (see "Base install" below).

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

The patched packages (camera kernel, qmlkonsole, kscreenlocker, plasma-mobile) are not in
git. Without them in `apks/` the base role skips them and the device runs stock packages.
Get them by copying the `.apk` files from a device that built them, or build them (dev
role, "Building packages").

## Roles

| Role | Default | Does |
|---|---|---|
| `base` | on | bash, keyd fixes, LED sleep hook, auto-rotation udev rule, zram, libcamera tuning, LibreWolf mobile UI, local apks |
| `dev` | off | toolchain, pipx tools (dtschema, b4), git identity, abuild key and dirs, kernel test slot units (dead-man switch, self-test) |
| `unattended` | off | **insecure**: passwordless sudo, lock screen off, LUKS keyfile in the initramfs. Enrol the key with `LUKS_PASSPHRASE=... ./bootstrap.sh --tags unattended` |
| `face_unlock` | off | Howdy from source with the PipeWire backend, config, PAM hook, enrolment launcher |

Values that differ per unit go in `inventory/host_vars/<hostname>.yml`; every one has a
default and a comment in `group_vars/all.yml`:

| Variable | How to find it |
|---|---|
| `keyd_keyboard_hash` | `sudo keyd monitor -t`, press a key on the dock keyboard |
| `howdy_pipewire_target` | `wpctl status` (front camera node) |
| `emmc_device` | `lsblk` (default `/dev/mmcblk1`) |
| `git_user_name`, `git_user_email` | yours (dev role; left alone while empty) |

Never commit: the abuild private key, the LUKS keyfile, `/etc/howdy/models/*`, any API
credentials.

## What each fix does

| Problem | Cause | Fix (where) | Role |
|---|---|---|---|
| Touchpad cursor jumps to the finger | Dock keyboard and touchpad share USB id 18d1:5057; cros-keyboard-map's keyd config grabs both | `[ids]` line narrowed to `k:18d1:5057:<keyboard hash>` (lineinfile in `roles/base`) | base |
| Closing the cover never suspends | keyd also matches the generic `k:0000:0000`, which on this detachable is `cros_ec_buttons`; its grab swallows `SW_LID` | `-0000:0000:<hash>` exclusion placed before `k:0000:0000` (keyd prefix-matches in file order) | base |
| No sign the tablet is asleep | nothing drives the charge LED on suspend | `files/usr/lib/systemd/system-sleep/led-sleep-indicator`: solid green while asleep (timer triggers freeze in deep sleep) | base |
| Auto-rotation 90 degrees off in tablet mode | stock hwdb accelerometer matrix assumes a landscape panel; this one is native portrait | `files/etc/udev/rules.d/61-cros-ec-accel.rules` (swap x/y, invert x). Mirrored? use `0, -1, 0; 1, 0, 0; 0, 0, -1` | base |
| zram tuning (more compressed swap, less reclaim churn) | pmOS default: zram 150% of RAM, default watermarks | `deviceinfo_zram_swap_pct="200"`; `files/etc/sysctl.d/99-zram-tuning.conf` (`watermark_boost_factor=0`, `watermark_scale_factor=125`) | base |
| No cameras | mainline has no SC7180 CAMSS support and no wormdingler camera DT | kernel patches 0006-0022, `patches/kernel/README.md`; libcamera tuning stubs in `files/usr/share/libcamera/` | base (apk) |
| No charge limit in Plasma | `cros_charge-control` needs ACPI and cannot find DT batteries | kernel patches 0029-0030 + `CONFIG_CHARGER_CROS_CONTROL=y`; Plasma's battery settings then show Charge Limit | base (apk) |
| Charge limit forgotten at every boot | the driver resets the EC to "no limit" on probe; PowerDevil does not store the value | `battery_charge_limit` (group_vars) -> `/etc/battery-charge-limit.conf`; `files/usr/local/sbin/battery-charge-limit` run by `battery-charge-limit.service` at boot and by `90-battery-charge-limit.rules` when the battery appears. Check: `scripts/ec-charge-control.py` | base |
| Terminal fills with stale pixels | qmlkonsole repaint bugs at fractional scale 1.25 on the 1200x2000 panel | `patches/qmlkonsole/` (framebuffer repaint + truncated content rect; the scroll-latch patch is parked, not reproduced on master) | base (apk) |
| LibreWolf shows the desktop UI | the `mobile-config-firefox-librewolf` stub replaces `librewolf.cfg` and with it LibreWolf's privacy defaults | stub removed; `files/HOME/.config/librewolf/.../librewolf.overrides.cfg` loads mobile-config-firefox from inside `librewolf.cfg`; fingerprinting protection with the UA exempt. Check: `scripts/librewolf-ua-test.sh` (40 s, expect `Mobile;` in the UA) | base |
| Face unlock | nothing packaged; the cameras exist only behind libcamera/PipeWire | Howdy + `patches/howdy/`, see "Face unlock" | face_unlock |
| First unlock after sleep needs a PIN | plasma-mobile's lock screen never re-arms the fingerprint slot on wake, and kscreenlocker ignores re-arm calls after a finished non-interactive run | `aports/plasma-mobile` (`onDpmsTurnedOn` re-arm) + `aports/kscreenlocker` (restart finished authenticators) | face_unlock (apk) |

Known leftovers: closing the cover on an already sleeping tablet wakes it (PowerDevil
re-suspends it; the fix is the EC wake mask); the touchscreen reports a phantom 0% battery
(needs a `HID_BATTERY_QUIRK_IGNORE` entry); the audio default may be a phantom headset
(`wpctl set-default`, not automated).

## Done by hand on purpose

### Base install

pmbootstrap 3.11 or newer from git (older releases do not know v26.06): device
`google-trogdor`, Plasma Mobile, systemd, full-disk encryption, nonfree firmware.
Reinstalling over an existing ChromeOS/pmOS disk crashes pmbootstrap on `blkid` exit 2:
wipe the partition table first. Change any throwaway install passwords afterwards.

### Kernel test slot (dev only, destructive)

Test kernels go to a second kernel partition p4, marked to boot once:

1. `sudo scripts/make-kernel-b-partition.sh` (dry run), then `--do-it`: shrinks `/boot` p2
   from 512 to 256 MiB and adds p4 `pmOS_kernel_b`. Backs up the GPT head first.
2. Enable the `dev` role: it installs `kernel-deadman` (reboots to p1 after 300 s unless
   blessed), `kernel-keep`, `dmesg-live` (`/boot/livelog/`) and `camera-selftest` (`/boot/camtest/`).
3. Flash a kernel: `scripts/patch-refresh.sh kernel --test` (packaged) or
   `scripts/build-kpart.sh --flash /dev/mmcblk1p4` (kernel tree), then
   `sudo cgpt add -i 4 -P 15 -T 1 -S 0 /dev/mmcblk1`.
4. Reboot. Only after you see a working desktop: `sudo kernel-keep`.

### Face unlock

`enable_face_unlock: true`, `./bootstrap.sh` (about 15 min: dlib compiles). Enrol with
`sudo howdy add <label>` or the "Howdy: add face" launcher; enrol again in the light you
unlock in (a model per lighting). `howdy-why` explains recent attempts from the journal.
Plasma 6.8 adds a real face slot: `docs/PLASMA-6.8-MIGRATION.md`.

### Building packages

The dev role sets up abuild (key generated per device, never copied; `SRCDEST` and
`REPODEST` from `group_vars`). Group `abuild` only applies after a new login, so use
`abuild -d` until then. Build and install through the refresh flow below, or by hand:
`cd aports/<pkg> && abuild checksum && abuild -d`, then
`sudo apk add --allow-untrusted <REPODEST>/aports/aarch64/<pkg>-<ver>.apk` (installed this
way, apk pins the package by checksum). The kernel takes about 2 h on the tablet.

## When an upstream moves: refresh the patch sets

Run `scripts/patch-refresh.sh all`. It prints, per project, our version vs upstream and stops.
Projects: `kernel`, `qmlkonsole`, `kscreenlocker`, `plasma-mobile`, `howdy`.

When one reports a newer upstream:

1. `scripts/patch-refresh.sh <project> --dry-run` (throw-away branches, shows the aport diff; ~5 min, kernel ~10)
2. `scripts/patch-refresh.sh <project> --apply` (rebases for real, regenerates the aport, commits or syncs, tags)
3. `scripts/patch-refresh.sh <project> --build` (abuild; kernel about 2 h)
4. `scripts/patch-refresh.sh <project> --test` (kernel: flashes p4, see "Kernel test slot")
5. `scripts/patch-refresh.sh <project> --install` (apk pins by checksum, then `sync.sh` + `check.sh`), then update `local_apks` in `group_vars/all.yml`

It needs `git`, `abuild` (dev role), network, and a git identity in this repo (commits
are made in that name). Upstream clones go under `$CODE` (default `~/code`) and are
cloned when missing; missing patch branches are rebuilt from the patch files here.
It stops on a rebase conflict, a patch that no longer applies, or a failed build, and says
where the worktree is. Config keys and the clone list: `refresh/README.md`.

Where the patches live:

| Project | Patches in this repo | Branch they are developed on | Upstream followed |
|---|---|---|---|
| kernel | `patches/kernel/` (pmaports package dir + `BASE`) | `wormdingler-camera-<ver>` in `$CODE/linux` | pmaports `origin/main` + stable tag |
| qmlkonsole | `patches/qmlkonsole/` (aport, built in place) | `fix/stale-framebuffer` in `$CODE/qmlkonsole` | Alpine `3.24-stable` + KDE tag |
| kscreenlocker, plasma-mobile | `aports/<pkg>/` (aport, built in place) | none, patch files only | pmaports `v26.06`, Alpine `3.24-stable` |
| howdy | `patches/howdy/` (format-patch + `BASE`) | `pmos-pipewire` in `$CODE/howdy` | GitHub master |

Tags: `wormdingler-camera/<ver>-r<rel>` (linux) and `linux-postmarketos-qcom-sc7180-<ver>-r<rel>`
(pmaports) per kernel package; `pmos-vXX.YY` on this repo per postmarketOS release.

## Sending patches upstream

Nothing here has been sent yet. Each patch set has one destination:

| Patch set | Destination | How |
|---|---|---|
| Kernel camera series (0006-0022) | linux-media, linux-arm-msm, devicetree, linux-clk | 15-patch series on linux-next: `patches/kernel/README.md` "Upstreaming" |
| Kernel charge limit (0029-0030) | linux-pm (power-supply), linux-acpi, chrome-platform | 2-patch series, applies unchanged to linux-next; same guide |
| libcamera tuning (`files/usr/share/libcamera/ipa/simple/`) | libcamera (`src/ipa/simple/data/`) | patch to libcamera-devel |
| qmlkonsole repaint fixes | KDE invent `plasma-mobile/qmlkonsole` | merge request from `fix/stale-framebuffer` (not the parked scroll-latch patch) |
| plasma-mobile, kscreenlocker | KDE invent `plasma/plasma-mobile`, `plasma/kscreenlocker` | merge requests from the patch files in `aports/` |
| Howdy PipeWire backend, musl and stamp fixes | github.com/boltgolt/howdy | pull request from `pmos-pipewire`; the nod and crashed-stamp fixes are security fixes, report them first |

Before sending, read the target's contribution policy. The kernel's rules are in
`Documentation/process/submitting-patches.rst` and `coding-assistants.rst`;
postmarketOS forbids contributions made with generative-AI tools, so check it before
proposing anything from this repo to pmaports.

## Keeping the repo and the device in sync

Rule: edit in the working tree or in this repo, apply with `bootstrap.sh`, never hand-copy.

1. Changed a patch branch or a system file: `./sync.sh`, review `git diff`, commit.
2. Does the device still match the repo: `./check.sh` (files, line edits, `apk audit`; `--ansible` adds a full `--check --diff`).
3. New whole file: add its path to `manifest.txt` under its role, run `./sync.sh`.
4. Value that differs per device: default in `group_vars/all.yml` + a template.
5. Package-owned file (like `/etc/keyd/default.conf`): a `lineinfile` task, never a copy, so apk upgrades don't fight it.

## Layout

```
manifest.txt        whole files managed verbatim: <role> <mode> <path>
files/              mirror of those paths, pulled from the live system by sync.sh (~ -> files/HOME/)
patches/kernel/     pmaports package dir (+ BASE commit); README.md: topics, rebase, upstreaming
patches/howdy/      format-patch of branch pmos-pipewire (+ BASE commit)
patches/qmlkonsole/ qmlkonsole aport with the repaint fixes
aports/             plasma-mobile and kscreenlocker aports with the lock screen fixes
apks/               built packages (gitignored; copy from a build host or rebuild)
refresh/            one config per patched project for patch-refresh.sh
roles/*/templates/  files with device-specific values
group_vars/all.yml  every parameter with its default; host_vars overrides per device
inventory/          *.example only; real hosts.yml and host_vars are gitignored
scripts/            patch-refresh.sh, lib-kernel-test.sh, build-kpart.sh, make-kernel-b-partition.sh,
                    build-howdy.sh, pamtest.c, librewolf-ua-test.sh, fake-boot-deploy/,
                    ec-charge-control.py (EC charge mode and battery sustainer bounds)
docs/               PLASMA-6.8-MIGRATION.md: moving face unlock to Plasma 6.8's native slot
```

## Building the kernel package by hand

`patches/kernel/linux-postmarketos-qcom-sc7180/` is the full pmaports package directory
(APKBUILD, config, 30 patches: 5 upstream pmOS, 17 camera, 6 already-upstream cci fixes,
2 EC charge limit; see `patches/kernel/README.md`), taken at the pmaports commit in `BASE`.

1. In a pmaports checkout at that commit, copy the directory over `device/community/linux-postmarketos-qcom-sc7180`.
2. `cd` into it, `abuild checksum && abuild -d` (see "Building packages").
3. Drop the apk in `apks/`.

When the camera series lands upstream this shrinks to the config change and the refresh flow retires.
