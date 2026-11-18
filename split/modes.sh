#!/usr/bin/env bash
# Runs one Roc file in every way roc offers, with each line of $INPUT on
# stdin in turn, and labels each output.
set -u
file="$1"
step() {
	echo "----- $1: $2"
	while IFS= read -r input; do
		printf '%s\n' "$input" | bash -c "$2" 2>&1 | grep -v "^0 errors and 0 warnings\|^ *$\|successfully building\|^    out-"
	done <<< "$INPUT"
}
rm -rf out-*
roc build --opt=dev --output=out-dev "$file" >/dev/null 2>&1
roc build --opt=interpreter --output=out-interp "$file" >/dev/null 2>&1
roc build --output=out-default "$file" >/dev/null 2>&1
roc build --opt=speed --output=out-speed "$file" >/dev/null 2>&1
roc build --opt=size --output=out-size "$file" >/dev/null 2>&1
step "run, no flags" "roc $file"
step "run subcommand" "roc run $file"
step "run --opt=dev" "roc --opt=dev $file"
step "run --opt=dev --no-cache" "roc --opt=dev --no-cache $file"
step "run --opt=interpreter" "roc --opt=interpreter $file"
step "run --opt=speed" "roc --opt=speed $file"
step "run --opt=size" "roc --opt=size $file"
step "built, no flags" "./out-default"
step "built --opt=dev" "./out-dev"
step "built --opt=interpreter" "./out-interp"
step "built --opt=speed" "./out-speed"
step "built --opt=size" "./out-size"
