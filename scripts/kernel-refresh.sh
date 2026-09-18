#!/bin/sh
# Compatibility wrapper: the kernel refresh is now `patch-refresh.sh kernel` (config in
# refresh/kernel.conf). Same options: --dry-run --apply --build --test --install
# --kernel-version X.Y.Z --force.
exec "$(dirname "$0")/patch-refresh.sh" kernel "$@"
