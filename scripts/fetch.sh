#!/usr/bin/env bash
# Fetches reference sources and the pinned 9front arm64 image into .local.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$HP9_ROOT/scripts/pins.sh"

mkdir -p "$HP9_LOCAL"/{bin,src,cache,9front}

clone() {
	local repo=$1 dir="$HP9_LOCAL/src/$2"
	if [ -d "$dir/.git" ]; then
		git -C "$dir" pull -q --ff-only
	else
		git clone -q --depth 1 "$repo" "$dir"
	fi
	echo "src/$2: $(git -C "$dir" rev-parse --short HEAD)"
}

clone "$HYPERLINUX_REPO" hyper-linux
clone "$NINEFRONT_REPO" 9front

img="9front-$NINEFRONT_RELEASE.arm64.qcow2"
if [ ! -f "$HP9_LOCAL/9front/$img" ]; then
	curl -fL --progress-bar -o "$HP9_LOCAL/9front/$img.gz" "$NINEFRONT_ISO_URL/$img.gz"
	gunzip "$HP9_LOCAL/9front/$img.gz"
fi
echo "9front/$img"
