#!/usr/bin/env bash
# Fetches reference sources, the pinned 9front arm64 image and prebuilt
# Unicorn libraries into .local.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$HP9_ROOT/scripts/pins.sh"

mkdir -p "$HP9_LOCAL"/{bin,src,cache,9front,unicorn}

# clone repo dir [rev]: a shallow clone at rev, or tracking the default
# branch if rev is empty.
clone() {
	local repo=$1 dir="$HP9_LOCAL/src/$2" rev=${3:-}
	if [ -n "$rev" ]; then
		[ -d "$dir/.git" ] || git init -q "$dir"
		if [ "$(git -C "$dir" rev-parse -q --verify HEAD || true)" != "$rev" ]; then
			git -C "$dir" fetch -q --depth 1 "$repo" "$rev"
			git -C "$dir" checkout -q --detach "$rev"
		fi
	elif [ -d "$dir/.git" ]; then
		git -C "$dir" pull -q --ff-only
	else
		git clone -q --depth 1 "$repo" "$dir"
	fi
	echo "src/$2: $(git -C "$dir" rev-parse --short HEAD)"
}

clone "$HYPERLINUX_REPO" hyper-linux
clone "$NINEFRONT_REPO" 9front "$NINEFRONT_REV"

img="9front-$NINEFRONT_RELEASE.arm64.qcow2"
if [ ! -f "$HP9_LOCAL/9front/$img" ]; then
	curl -fL --progress-bar -o "$HP9_LOCAL/9front/$img.gz" "$NINEFRONT_ISO_URL/$img.gz"
	gunzip "$HP9_LOCAL/9front/$img.gz"
fi
echo "9front/$img"

# Unicorn: headers and libunicorn.a for each target into .local/unicorn/<name>.
echo "$UNICORN_WHEELS" | while read -r name tag sha; do
	[ -n "$name" ] || continue
	dir="$HP9_LOCAL/unicorn/$name"
	if [ ! -f "$dir/lib/libunicorn.a" ]; then
		whl="$HP9_LOCAL/cache/unicorn-$UNICORN_VERSION-$tag.whl"
		curl -fsSL -o "$whl" "$UNICORN_WHEEL_URL/unicorn-$UNICORN_VERSION-py2-none-$tag.whl"
		echo "$sha  $whl" | shasum -a 256 -c --quiet
		rm -rf "$dir" "$dir.tmp"
		unzip -q "$whl" 'unicorn/lib/libunicorn.a' 'unicorn/include/*' -d "$dir.tmp"
		mv "$dir.tmp/unicorn" "$dir"
		rm -rf "$dir.tmp" "$whl"
	fi
	echo "unicorn/$name: $UNICORN_VERSION"
done
