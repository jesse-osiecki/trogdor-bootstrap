# Face unlock: moving from the fingerprint slot to Plasma 6.8's real Face slot

Written 2026-09-11 so this can be picked up cold months later. Read the README
section "Face unlock" first if the setup itself is hazy. `<user>` below is the
device user (the one who enrolled the face). Nothing here is urgent: the
fingerprint-slot hack keeps working on Plasma 6.8, it just keeps saying
"fingerprint" on the lock screen.

## 0. The one-paragraph mental model

Howdy is a PAM module (`/usr/lib/security/pam_howdy.so`). It runs a Python
process (`/opt/howdy/venv/bin/python3 /usr/lib/howdy/compare.py <user>`) that
grabs frames from the front camera through PipeWire, matches them against
`/etc/howdy/models/<user>.dat`, then runs the nod check (switched off by default). The Plasma lock screen
greeter runs a few PAM "services" side by side: `kde` (password) plus some
non-interactive ones that silently unlock on success. On Plasma 6.6 the only
non-interactive slots are `kde-fingerprint` and `kde-smartcard`, so Howdy sits
in `/etc/pam.d/kde-fingerprint`. Plasma 6.8 adds a `kde-face` slot and a config
switch for it. The migration is: put the same PAM line in the new file, flip the
switch, give the fingerprint file back.

## 1. How to tell 6.8 has arrived

```
apk info kscreenlocker | head -1        # want 6.8.x or newer (was 6.6.6-r0)
apk info plasma-desktop | head -1       # the lock screen QML lives here; must also be 6.8+
ls /etc/pam.d/kde-face                  # 6.8 packages may ship a template
strings -e l /usr/lib/libexec/kscreenlocker_greet | grep -iE '^(kde-face|Face)$'
```

The last command prints `kde-face` and `Face` when the greeter knows the slot
(Qt strings are UTF-16, hence `-e l`). Background: the kscreenlocker merge
request that adds it is invent.kde.org/plasma/kscreenlocker/-/merge_requests/318
(merged 2026-08-18, milestone 6.8), with companions plasma-workspace!6542 and
plasma-desktop!3689. Plasma 6.8.0 was scheduled for 2026-10-14. postmarketOS
stable v26.06 stays on 6.6; the next stable (v26.12) is the first that carries
6.8. Edge got it whenever Alpine packaged 6.8.0.

## 2. First, check the upgrade did not break Howdy itself

A big apk upgrade can move things under the venv. Run these before touching PAM:

```
/opt/howdy/venv/bin/python3 -c "import dlib, cv2, numpy, gi; print(dlib.__version__)"
sudo howdy list
gcc -O1 -o /tmp/pamtest scripts/pamtest.c -lpam     # from this repo
/tmp/pamtest kde-fingerprint "$USER"    # look at the camera: expect rc=0
grep -n '^recording_plugin' /etc/howdy/config.ini   # must say pipewire
```

If the first line fails with an import error, the system Python's major version
changed (the venv was built on 3.14) or numpy/opencv changed ABI. Rebuild the venv:

```
sudo rm -rf /opt/howdy/venv
sudo sh -c 'python3 -m venv --system-site-packages /opt/howdy/venv && \
  CMAKE_BUILD_PARALLEL_LEVEL=8 /opt/howdy/venv/bin/pip install --no-cache-dir dlib'
```

(~10 min; needs `cmake g++ python3-dev openblas-dev lapack-dev` which are installed).
The PAM module and python files under `/usr/lib/howdy` are not apk-managed, so an
upgrade leaves them alone. If you ever need to rebuild them:

```
sudo scripts/build-howdy.sh                          # upstream BASE + patches/howdy, from this repo
grep -n '^recording_plugin' /etc/howdy/config.ini   # must say pipewire
```

If `config.ini` got clobbered: `./bootstrap.sh --tags face_unlock` writes it again from
`roles/face_unlock/templates/config.ini.j2`.

## 2b. Our Howdy patches, and whether you still need them

Howdy here is upstream master at `patches/howdy/BASE` (d3ab993, 3.0.0 beta, June 2025)
plus the patches in `patches/howdy/`, exported from branch `pmos-pipewire` in
`$CODE/howdy` (`scripts/patch-refresh.sh howdy` creates that clone). 0001 has the five
parts below; 0002 adds `[video] detection_threshold`, 0003 makes compare.py log to
stderr when stdout is not a terminal (needed by `howdy-why`).

| Part | Why we needed it | Still needed if... |
|---|---|---|
| `recorders/pipewire_reader.py` + hook in `video_capture.py` + config keys | Howdy's opencv/ffmpeg/pyv4l2 backends open `/dev/videoN`; our cameras only exist behind libcamera, which PipeWire owns | upstream still has no libcamera/PipeWire backend (check `ls howdy/src/recorders/` on their master) |
| `pam/main.cc`: pass `environ` to `posix_spawnp` | a null envp is an empty environment on musl, so compare.py could not find PipeWire's socket | upstream still passes `nullptr` (glibc users never notice, so it may never change) |
| `pam/meson.build`: `dependency('intl')` | musl keeps gettext in libintl; link failed | upstream did not add it |
| `rubberstamps/nod.py`: return `failsafe` on timeout, not `not failsafe` | the nod stamp approved anyone who did not nod | upstream line still reads `return not self.options["failsafe"]` |
| `rubberstamps/__init__.py`: guard UI writes, fail closed on a crashed faildeadly stamp | `howdy-gtk` cannot start on Wayland, the stamp crashed on a broken pipe, and the crash was swallowed as a pass | upstream still has the bare `continue` after `traceback.print_exc()` |

None of this is tied to Plasma 6.8. The migration in section 3 changes PAM
files and one config key; Howdy itself, patched or not, does not care which
slot calls it. So: **do not rebuild Howdy as part of the 6.8 move.** Only
revisit the patch when you deliberately update Howdy, and then check each row
above against their tree first, because any of the five may have been fixed
upstream by then (the nod and pipe fixes are the likeliest, since issue 916
already describes the symptom; the PipeWire backend is the least likely).
To see what has changed upstream since our base:

```
scripts/patch-refresh.sh howdy               # compares patches/howdy/BASE with upstream master
git -C $CODE/howdy diff d3ab993 origin/master -- howdy/src/rubberstamps howdy/src/pam/main.cc howdy/src/recorders
```

If you do update: `scripts/patch-refresh.sh howdy --dry-run`, then `--apply` (rebases
`pmos-pipewire` and re-exports `patches/howdy/`), drop any commit upstream made
redundant, then `--build`.

## 3. The migration itself

1. See whether apk left the fingerprint file alone. It leaves modified `/etc` files
   in place and drops the package's version as `.apk-new`:
   ```
   ls /etc/pam.d/kde-fingerprint*
   cat /etc/pam.d/kde-face 2>/dev/null
   ```
2. Create the face service (the same line we used in the fingerprint slot):
   ```
   sudo tee /etc/pam.d/kde-face >/dev/null <<'PAM'
   #%PAM-1.0
   # Lock screen face unlock through Howdy (Plasma >= 6.8 Face slot)
   -auth      required    pam_howdy.so
   account    include     base-account
   PAM
   ```
   If the package shipped a `kde-face` template, overwrite it; KDE's own
   suggestion for that file is exactly `-auth required pam_howdy.so`.
3. Give the fingerprint slot back so the lock screen stops calling it a fingerprint:
   ```
   sudo cp /etc/howdy/kde-fingerprint.pmos-orig /etc/pam.d/kde-fingerprint
   sudo rm -f /etc/pam.d/kde-fingerprint.apk-new
   ```
   (Or use the `.apk-new` file if it exists, it is the newer template.)
4. Turn the Face authenticator on for your user:
   ```
   kwriteconfig6 --file kscreenlockerrc --group Authenticators --key Face true
   grep -A3 Authenticators ~/.config/kscreenlockerrc
   ```
   The MR's example config block was `[Authenticators]` with `Smartcard=true`,
   `Fingerprint=true`, `Face=true`, `Universal2Factor=true`. Verify the key names
   against the installed version before trusting this: `strings -e l
   /usr/lib/libexec/kscreenlocker_greet | grep -iE 'Authenticators|^Face$'`, or
   read `greeter/pamauthenticators.cpp` of the installed version at
   `https://raw.githubusercontent.com/KDE/kscreenlocker/Plasma/6.8/greeter/pamauthenticators.cpp`
   (note the `[Greeter] Authenticator=` key there is the *selected* authenticator
   for the switcher UI, not the enable switch). Optionally set `Fingerprint false`
   so a non-existent reader is never mentioned.
5. Test without locking, then for real:
   ```
   /tmp/pamtest kde-face "$USER"         # look: rc=0. No model -> rc=9, camera error -> rc=7 quickly
   /tmp/pamtest kde-fingerprint "$USER"  # now expect a fast failure, it no longer runs Howdy
   loginctl lock-session
   ```
   The lock screen should show a face hint (or a selector) instead of the
   fingerprint text. Debug with `sudo journalctl -t pam_howdy` and
   `sudo journalctl --user -b | grep -i kscreenlocker_greet`.

Nothing in Howdy's own config changes for this. `workaround = off` must stay off:
the non-interactive slots never show a password prompt, so the "type Enter for
me" workarounds would only cause trouble.

## 4. If 6.8 changed the greeter in a way this document did not foresee

The invariants to check, in order:

- Is Howdy fine on its own? `pamtest kde-face "$USER"` (section 2 builds pamtest).
- Does the greeter start the `kde-face` service at all? Run the greeter in test
  mode from a terminal in the session, it does real PAM auth in a window and logs
  what it starts:
  ```
  QT_LOGGING_RULES='kscreenlocker*=true' /usr/lib/libexec/kscreenlocker_greet --testing 2>&1 | grep -i 'pam worker'
  ```
- Is the config switch what enables it? Look at how `noninteractive` authenticators
  are constructed in the installed version's `greeter/greeterapp.cpp` or
  `pamauthenticators.cpp` (KDE mirror: github.com/KDE/kscreenlocker, branch
  `Plasma/6.8`). On 6.6 they were created unconditionally; 6.8 reads config.

## 5. Optional while you are at it

- Add a second face model for other light/glasses: the launcher entry
  "Howdy: add face" (or `sudo howdy add <label>`).
- Report the two upstream bugs found here (see section 2b): the nod stamp
  returns the inverted result on timeout (`nod.py`, since 2021) and a crashing
  stamp is skipped and approves (`rubberstamps/__init__.py`), which is what
  happens on every Wayland desktop because `howdy-gtk --start-auth-ui` cannot
  start there. Issue 916 on github.com/boltgolt/howdy already describes the
  symptom without the security angle. The fixes are in `patches/howdy/0001-*.patch`.
- Consider `certainty` in `/etc/howdy/config.ini` (3.5 now; higher is more lenient).

## 6. Files this touches, for the record

| Path | What |
|---|---|
| `/etc/pam.d/kde-fingerprint` | currently the Howdy line; restore from `/etc/howdy/kde-fingerprint.pmos-orig` |
| `/etc/pam.d/kde-face` | new in this migration |
| `~/.config/kscreenlockerrc` | `[Authenticators] Face=true`; also holds the autolock=false lines from the unattended-boot setup |
| `/etc/howdy/config.ini` | Howdy settings; template `roles/face_unlock/templates/config.ini.j2` |
| `/etc/howdy/models/<user>.dat` | enrolled faces (root-owned, world-readable, needed by the greeter which runs as the user); personal, never copied |
| `/opt/howdy/venv` | Python with dlib |
| `/usr/lib/howdy`, `/usr/lib/security/pam_howdy.so`, `/usr/bin/howdy`, `/usr/share/dlib-data` | Howdy install (meson, not apk) |
| `$CODE/howdy` | source, branch `pmos-pipewire` (created by `patch-refresh.sh howdy`) |
| this repo | `patches/howdy/`, `files/etc/pam.d/kde-fingerprint`, `scripts/pamtest.c`, `scripts/build-howdy.sh`, this file |
