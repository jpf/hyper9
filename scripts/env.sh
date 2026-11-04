# Source this from the repo root: . scripts/env.sh
H9_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
export H9_ROOT
export H9_LOCAL="$H9_ROOT/.local"
export ZIG_GLOBAL_CACHE_DIR="$H9_LOCAL/cache/zig"
export PATH="$H9_ROOT/zig-out/bin:$H9_LOCAL/bin:$PATH"
if [ "$(uname)" = Darwin ] && [ -z "${SDKROOT:-}" ]; then
	SDKROOT=$(xcrun --show-sdk-path 2>/dev/null) && export SDKROOT
fi
