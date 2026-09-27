# patches/kernel: the local kernel patch set for google-trogdor wormdingler

`linux-postmarketos-qcom-sc7180/` is the complete pmaports package directory
(APKBUILD, config, patches) as it exists on pmaports branch `wormdingler-camera`, taken
against the pmaports `origin/main` commit recorded in `BASE`. `sync.sh` regenerates it;
never edit the files here by hand.

## The patches are four independent topics, not one

The numbering is just the order in the APKBUILD. The topics are separate pieces of work
with separate upstream destinations; a rebase can drop one without touching the others.

| Patches | Topic | Author(s) | Where it is going | Drop when |
|---|---|---|---|---|
| 0001-0005 | drm/msm GPU fixes | Akhil P Oommen | **Not ours.** Shipped by the upstream pmOS aport at `BASE`; they are the aport's own `source=` patches | pmOS drops them |
| 0006-0022 | Camera bring-up: CAMSS SC7180, CCI binding, gcc clk, ov8856 fixes, DT (CAMSS, CCI0, wormdingler sensors) | George Chan (5), Jesse (12) | One 15-17 patch series to linux-media / arm-msm; drafts in `trogdor-support/upstream/` | the series is in a stable release |
| 0023-0028 | i2c-qcom-cci fixes | Vladimir Zapolskiy, Wenmeng Liu, Guangshuo Li | **Already upstream** (7.x); carried only because 6.18 lacks them | the kernel moves past the version that has them (the refresh script drops them by subject match) |
| 0029-0030 | EC battery charge limit: ACPI battery-hook stubs + `cros_charge-control` without ACPI | Jesse | Separate 2-patch series to linux-pm (power-supply) + linux-acpi; drafts in `trogdor-support/upstream/charge-control/` | the series is in a stable release |

Config additions per topic live in `../../scripts/kernel-config-fragment` (commented by topic).
The kernel config in this directory already has them applied.

Historical naming: the git branch that carries all of ours (0006-0030) is called
`wormdingler-camera-<version>` (in `~/code/linux`) and the pmaports branch `wormdingler-camera`,
because the camera work came first. The names do not mean "camera only".

## Where each form of the patches lives

| Form | Location | Role |
|---|---|---|
| git commits | `~/code/linux` branch `wormdingler-camera-<ver>` (worktree `~/code/linux-<ver>`), one commit per patch, topics in the order above | where patches are developed and rebased |
| patch files + APKBUILD + config | pmaports branch `wormdingler-camera`, `device/community/linux-postmarketos-qcom-sc7180/` | what abuild builds |
| copy of the above | this directory (+ `BASE`) | what a fresh clone of this repo has; the scripts rebuild the two branches from it |
| upstream drafts | `~/code/trogdor-support/upstream/` (camera), `.../upstream/charge-control/` | what gets mailed, after Jesse's OK |

Tags: `wormdingler-camera/<ver>-r<rel>` on the linux branch and
`linux-postmarketos-qcom-sc7180-<ver>-r<rel>` on pmaports mark what each built package contained.

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
5. Commits the aport as Jesse, tags both repos, runs `sync.sh` so this directory follows.

### By hand (if the script is unavailable or you distrust it)

Time: about 30 min plus the 2 h build.

1. `git -C ~/code/linux fetch origin tag v<new>` and
   `git worktree add ~/code/linux-<new> -b wormdingler-camera-<new> wormdingler-camera-<old>`.
2. `git rebase --onto v<new> v<old>` in that worktree. For each conflict: if
   `git log --oneline v<old>..v<new> | grep -F "<subject>"` finds it, `git rebase --skip`;
   otherwise fix it, keeping the topic boundaries above.
3. In pmaports: `git rebase origin/main wormdingler-camera`, resolve the APKBUILD in favour of
   upstream, then delete our old `00xx-*.patch` files and
   `git -C ~/code/linux-<new> format-patch --no-signature --start-number $((N+1)) -o . v<new>..wormdingler-camera-<new>`
   where N is the number of patches upstream's `source=` already lists. Add the new names to
   `source=` before `$_config`, bump `pkgrel`.
4. Config: for each line in `scripts/kernel-config-fragment`,
   `~/code/linux-<new>/scripts/config --file config-*.aarch64 --enable|--module NAME`, then
   `make ARCH=arm64 LLVM=1 olddefconfig` with that file as `.config` and copy it back.
5. `abuild checksum && abuild -d`; test with `. scripts/lib-kernel-test.sh; kernel_test_p4 <apk>`.
6. `./sync.sh`, review, commit as Jesse; tag both repos.

Adding a new topic: commit it at the end of `wormdingler-camera-<ver>`, add its config lines
to the fragment under its own comment, export as above, and add a row to the table here.
