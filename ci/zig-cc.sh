#!/usr/bin/env bash
# C-compiler shim so cc-rs (used by the bundled libsqlite3-sys) can cross-compile
# C to musl using `zig cc`, avoiding the need for a musl-gcc cross toolchain in
# CI. scripts/build.py points CC_<triple> at this script for *-linux-musl targets and
# sets ZIG_CC_TARGET to the zig target triple (e.g. x86_64-linux-musl).
#
# cc-rs passes the *rust* triple via `--target=...`; zig wants its own triple, so
# we strip the incoming target flags and substitute ZIG_CC_TARGET.
set -euo pipefail

: "${ZIG_CC_TARGET:?ZIG_CC_TARGET must be set (e.g. x86_64-linux-musl)}"
ZIG_BIN="${ZIG:-zig}"

args=()
skip_next=false
for a in "$@"; do
    if [ "$skip_next" = true ]; then
        skip_next=false
        continue
    fi
    case "$a" in
        --target=*) continue ;;
        -target) skip_next=true; continue ;;
        x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) continue ;;
        *) args+=("$a") ;;
    esac
done

exec "$ZIG_BIN" cc -target "$ZIG_CC_TARGET" "${args[@]}"
