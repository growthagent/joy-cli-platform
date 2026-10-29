#!/usr/bin/env bash
# Archiver shim companion to zig-cc.sh — lets cc-rs create static archives with
# `zig ar` when cross-compiling C to musl. scripts/build.py points AR_<triple> here.
set -euo pipefail
ZIG_BIN="${ZIG:-zig}"
exec "$ZIG_BIN" ar "$@"
