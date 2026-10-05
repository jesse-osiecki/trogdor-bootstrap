# Instructions for agents working in trogdor-bootstrap

This repo is public (github.com/jesse-osiecki/trogdor-bootstrap) and is the only home for
everything that reproduces or helps with a trogdor device: Ansible roles, `files/` (via
`manifest.txt`), `patches/`, `aports/`, `refresh/`, `scripts/`, `docs/`. The private diary is
`~/code/trogdor-support`; the inventory and the standing rules are `~/code/INDEX.md` and
`~/code/CLAUDE.md`. Read those first.

## Push your own commits, every time, without asking
Jesse's standing instruction (2026-10-05): a commit you make in this repo is pushed to
`origin main` right away, in the same turn, with no prompt. This is the one repo where the
"nothing goes out without an OK" rule is pre-approved. Before each push:

1. `git log --format='%an <%ae> | %cn <%ce>' origin/main..HEAD | sort | uniq -c` shows only
   `Jesse Osiecki <jesse@jjo.ninja>`.
2. `git log --format=%B origin/main..HEAD | grep -i -E 'co-authored|claude|anthropic|generated with'`
   finds nothing.
3. `git diff origin/main..HEAD` carries no keys, passwords, tokens, MAC or IP addresses, session ids.
4. Push with Jesse's agent: `SSH_AUTH_SOCK=$HOME/.ssh/agent.sock git push origin main`.
   If the agent is locked, say so in the reply instead of waiting silently; never touch the key
   itself. Never force-push; on a non-fast-forward, fetch, rebase your commits, push again.

Other unpushed commits on `main` (from another session) ride along; they are covered by the same
audit, which is why step 1 and 2 look at everything between `origin/main` and `HEAD`.

## Everything else
- Commits authored and committed as `Jesse Osiecki <jesse@jjo.ninja>`, no agent attribution of
  any kind (see `~/.claude/CLAUDE.md` rule 1).
- Nothing in the repo may point outside it; scripts clone what they need (`CODE=` override).
- A script, diagnostic, rule, unit or helper anyone might run again lives in `scripts/` or the
  matching role, and is listed in `README.md`. Do not put such things in trogdor-support.
- After changing a patch branch or a system file: `./sync.sh`, review, commit; `./check.sh` must
  report no drift before a task is called done. Update `~/code/INDEX.md` in the same session.
