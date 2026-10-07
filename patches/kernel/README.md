# patches/kernel: the local kernel patch set for google-trogdor wormdingler

`linux-postmarketos-qcom-sc7180/` is the complete pmaports package directory
(APKBUILD, config, patches) as it exists on pmaports branch `wormdingler-camera`. `BASE` is the
pmaports `main` commit that branch is based on (its merge-base with `origin/main`), so
`git diff BASE..wormdingler-camera -- device/community/linux-postmarketos-qcom-sc7180` is exactly our change. `sync.sh` regenerates it;
never edit the files here by hand.

## The patches are four independent topics, not one

The numbering is just the order in the APKBUILD. The topics are separate pieces of work
with separate upstream destinations; a rebase can drop one without touching the others.

| Patches | Topic | Author(s) | Where it is going | Drop when |
|---|---|---|---|---|
| 0001-0005 | drm/msm GPU fixes | Akhil P Oommen | **Not ours.** Shipped by the upstream pmOS aport at `BASE`; they are the aport's own `source=` patches | pmOS drops them |
| 0006-0022 | Camera bring-up: CAMSS SC7180, CCI binding, gcc clk, ov8856 fixes, DT (CAMSS, CCI0, wormdingler sensors) | George Chan (5), Jesse Osiecki (12) | One 15-patch series to linux-media / arm-msm, see "Upstreaming" below | the series is in a stable release |
| 0023-0028 | i2c-qcom-cci fixes | Vladimir Zapolskiy, Wenmeng Liu, Guangshuo Li | **Already upstream** (7.x); carried only because 6.18 lacks them | the kernel moves past the version that has them (the refresh script drops them by subject match) |
| 0029-0032 | EC battery charge limit: ACPI battery-hook stubs, `cros_charge-control` without ACPI, take over the limit the EC kept across a reboot, disable the sustainer before reprogramming it (EC drops it otherwise) | Jesse Osiecki | Separate 4-patch series to linux-pm (power-supply) + linux-acpi, see "Upstreaming" below | the series is in a stable release |

Config additions per topic live in `../../scripts/kernel-config-fragment` (commented by topic).
The kernel config in this directory already has them applied.

Historical naming: the git branch that carries all of ours (0006-0032) is called
`wormdingler-camera-<version>` (in `$CODE/linux`) and the pmaports branch `wormdingler-camera`,
because the camera work came first. The names do not mean "camera only".

## Where each form of the patches lives

| Form | Location | Role |
|---|---|---|
| git commits | `$CODE/linux` branch `wormdingler-camera-<ver>` (optionally a worktree `$CODE/linux-<ver>`), one commit per patch, topics in the order above | where patches are developed and rebased |
| patch files + APKBUILD + config | pmaports branch `wormdingler-camera`, `device/community/linux-postmarketos-qcom-sc7180/` | what abuild builds |
| copy of the above | this directory (+ `BASE`) | what a fresh clone of this repo has; the scripts rebuild the two branches from it |
| upstream series | generated from the git commits onto linux-next, see "Upstreaming" | what gets mailed |

Tags: `wormdingler-camera/<ver>-r<rel>` on the linux branch and
`linux-postmarketos-qcom-sc7180-<ver>-r<rel>` on pmaports mark what each built package contained.

## One modules directory per package build

Since 6.18.40-r3 the APKBUILD's `prepare()` sets `CONFIG_LOCALVERSION="-r$pkgrel"`, so the
kernel release is `6.18.40-r3` and its modules live in `/lib/modules/6.18.40-r3`. Reason
(incident 2026-10-06): the test flow stages the new package's modules on the live system while
the blessed kernel in p1 still runs the previous build; with one shared `/lib/modules/6.18.40`
the blessed kernel lost its modules (signed, BTF-checked: another build's modules do not load)
and the next initramfs had no input drivers at the LUKS prompt. `patch-refresh.sh` re-adds the
line on every regeneration (`APKBUILD_PREPARE_EXTRA` in `refresh/kernel.conf`);
`lib-kernel-test.sh` refuses a release that equals the installed one or belongs to a package.

## Rebasing onto a newer kernel

### With the script (normal path)

```
scripts/patch-refresh.sh kernel              # compare our version with pmaports origin/main
scripts/patch-refresh.sh kernel --dry-run    # rebase on throw-away branches, show the aport diff
scripts/patch-refresh.sh kernel --apply      # rebase for real, regenerate the aport, commit, tag
scripts/patch-refresh.sh kernel --build      # abuild -d, about 2 h on the tablet
scripts/patch-refresh.sh kernel --test       # kpart to the unproven p4 slot; you reboot and bless
scripts/patch-refresh.sh kernel --install    # apk add (pinned by checksum), sync.sh, check.sh
```

What `--apply` does, so you can judge its output:

1. Rebases pmaports branch `wormdingler-camera` onto `origin/main` (picks up the new upstream
   aport: new `pkgver`, new set of upstream `source=` patches, new config).
2. Rebases our linux branch onto the new stable tag `v<ver>` as `wormdingler-camera-<ver>`.
   A commit that conflicts is dropped if its subject already exists in `v<old>..v<new>`
   (that is how the cci fixes will disappear) or is listed in `refresh/kernel.skip`;
   any other conflict stops the script and leaves the worktree for you.
3. Re-exports our commits with `git format-patch --no-signature`, numbered after the upstream
   aport's own patches, into the aport; inserts the names before `$_config` in `source=`.
4. Applies `scripts/kernel-config-fragment` to the upstream config with `scripts/config`
   and runs `olddefconfig`, then `abuild checksum`.
5. Commits the aport with your git identity, tags both repos, runs `sync.sh` so this directory follows.

### By hand (if the script is unavailable or you distrust it)

Time: about 30 min plus the 2 h build.

1. `git -C $CODE/linux fetch origin tag v<new>` and
   `git -C $CODE/linux worktree add $CODE/linux-<new> -b wormdingler-camera-<new> wormdingler-camera-<old>`.
2. `git rebase --onto v<new> v<old>` in that worktree. For each conflict: if
   `git log --oneline v<old>..v<new> | grep -F "<subject>"` finds it, `git rebase --skip`;
   otherwise fix it, keeping the topic boundaries above.
3. In pmaports: `git rebase origin/main wormdingler-camera`, resolve the APKBUILD in favour of
   upstream, then delete our old `00xx-*.patch` files and
   `git -C $CODE/linux-<new> format-patch --no-signature --start-number $((N+1)) -o . v<new>..wormdingler-camera-<new>`
   where N is the number of patches upstream's `source=` already lists. Add the new names to
   `source=` before `$_config`, bump `pkgrel`. Keep the `./scripts/config --set-str LOCALVERSION "-r$pkgrel"`
   line in `prepare()` (see above).
4. Config: for each line in `scripts/kernel-config-fragment`,
   `$CODE/linux-<new>/scripts/config --file config-*.aarch64 --enable|--module NAME`, then
   `make ARCH=arm64 LLVM=1 olddefconfig` with that file as `.config` and copy it back.
5. `abuild checksum && abuild -d`; test with `. scripts/lib-kernel-test.sh; kernel_test_p4 <apk>`.
6. `./sync.sh`, review, commit; tag both repos.

Adding a new topic: commit it at the end of `wormdingler-camera-<ver>`, add its config lines
to the fragment under its own comment, export as above, and add a row to the table here.

## Upstreaming

The files here are the **postmarketOS build copy** (6.18 stable base, pmaports numbering).
They are not what gets mailed. An upstream series is generated from the same commits,
rebased onto linux-next (or the subsystem's `for-next`), with upstream-style changelogs.

How far the two forms drift (measured 2026-09-27 against the v3 camera series prepared
on next-20260903):

| Topic | Code difference | Message difference |
|---|---|---|
| Camera 0006-0022 | Same changes. linux-next needed: regulators as `{ .supply = "..." }` structs, new `CAMSS_6150`/`CAMSS_6350` neighbours in the enums and switch, different DT context lines. 0017-0018 (ov8856 orientation/rotation + its binding) are **dropped**: linux-next already has them. 17 patches become 15. | Upstream messages were rewritten: full wiring description, `[Jesse Osiecki: ...]` notes on George Chan's patches, no `cherry picked from` lines, full name in `Signed-off-by`. |
| Charge limit 0029-0032 | Identical; applies unchanged to next-20260903. | Identical apart from numbering. |
| cci fixes 0023-0028 | Not sent: already upstream. | |

Current state (2026-09-27): both series sit on mainline `v7.3-rc4` as branches of
github.com/jesse-osiecki/linux: `sc7180-camss` (15 commits) and `cros-charge-control`
(2 commits). Done: checkpatch --strict (0 errors), `dt_binding_check` and `CHECK_DTBS=y`
clean, every commit builds on its own with `W=1`. Nothing has been mailed. Left:

1. Boot test the rc4 branch on the device (p4 test slot): both cameras stream, the charge
   limit works, then `sudo kernel-keep`.
2. Just before sending, rebase a copy onto the newest linux-next and rebuild (step 2 below).
3. Steps 5-6 below (recipients, format-patch with "Changes since v3", dry run, send).

Steps for a new submission (per series; about 1 h plus a build and a boot test):

1. Get a linux-next tree: `git -C $CODE/linux fetch https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git tag next-<date>`.
2. `git -C $CODE/linux worktree add $CODE/linux-next -b <topic>-next next-<date>`, then
   `git am` the topic's patches from this directory. Resolve the conflicts named in the
   table above; drop what the table says is already there.
3. Rewrite each changelog for upstream (`git rebase -i`, reword). Keep other authors'
   `From:` and `Signed-off-by:`; describe your changes to their patches in a
   `[Name: ...]` note above your own `Signed-off-by:`.
4. Check: `./scripts/checkpatch.pl --strict`, `make dt_binding_check` and `make dtbs_check`
   for binding/DT patches, a build of every commit, and a boot of the result
   (`scripts/build-kpart.sh --flash <disk>p4` from this repo, then the p4 test flow).
5. Recipients: `./scripts/get_maintainer.pl` over the series; add George Chan
   `<gchan9527@gmail.com>` in Cc for the camera series (co-author).
6. `git format-patch -v<N> --cover-letter --base=auto` and a dry run with
   `git send-email --dry-run` (or `b4 send --dry-run`) before the real send.

Contribution policies to check before sending anything:

- Linux: `Documentation/process/submitting-patches.rst` (DCO: `Signed-off-by` is a
  personal statement) and `Documentation/process/coding-assistants.rst` (disclosure
  rules for tool-assisted work). Which tags a submission carries is the submitter's call.
- postmarketOS: its contributing policy forbids contributions created with generative-AI
  tools. Read it before proposing anything from this repo to pmaports; the config-only
  change (three `=m` options) is small enough to write by hand.
