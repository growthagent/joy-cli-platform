#!/usr/bin/env bash
# Runs one Roc file in every way roc offers and labels each output.
set -u
file="$1"
step() {
	echo "----- $1: $2"
	bash -c "$2" 2>&1 | grep -v "^0 errors and 0 warnings\|^ *$\|successfully building\|^    out-"
	echo "(exit ${PIPESTATUS[0]})"
}
rm -rf out-*
step "run, no flags" "roc $file"
step "run subcommand" "roc run $file"
step "run --opt=dev" "roc --opt=dev $file"
step "run --opt=dev --no-cache" "roc --opt=dev --no-cache $file"
step "run --opt=interpreter" "roc --opt=interpreter $file"
step "run --opt=speed" "roc --opt=speed $file"
step "run --opt=size" "roc --opt=size $file"
step "build, no flags" "roc build --output=out-default $file && ./out-default"
step "build --opt=dev" "roc build --opt=dev --output=out-dev $file && ./out-dev"
step "build --opt=interpreter" "roc build --opt=interpreter --output=out-interp $file && ./out-interp"
step "build --opt=speed" "roc build --opt=speed --output=out-speed $file && ./out-speed"
