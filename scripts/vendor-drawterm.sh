#!/usr/bin/env bash
# Adds or updates third_party/drawterm as a squashed git subtree at
# $DRAWTERM_REV (scripts/pins.sh). Local changes to the tree are kept:
# updates are merges, so commit or stash work first.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$H9_ROOT/scripts/pins.sh"
cd "$H9_ROOT"

prefix=third_party/drawterm
src="$H9_LOCAL/src/drawterm"
if [ ! -d "$src/.git" ]; then
	git clone -q "$DRAWTERM_REPO" "$src"
fi
if ! git -C "$src" cat-file -e "$DRAWTERM_REV^{commit}" 2>/dev/null; then
	git -C "$src" fetch -q origin
fi

git fetch -q "$src" "$DRAWTERM_REV"
msg="Vendor drawterm ${DRAWTERM_REV:0:12} from $DRAWTERM_REPO"
if [ -d "$prefix" ]; then
	git subtree merge --prefix="$prefix" --squash -m "$msg" "$DRAWTERM_REV"
else
	git subtree add --prefix="$prefix" --squash -m "$msg" "$DRAWTERM_REV"
fi
