# Source this from the repo root: . scripts/env.sh
HP9_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
export HP9_ROOT
export HP9_LOCAL="$HP9_ROOT/.local"
export ZIG_GLOBAL_CACHE_DIR="$HP9_LOCAL/cache/zig"
export PATH="$HP9_LOCAL/bin:$PATH"
if [ "$(uname)" = Darwin ] && [ -z "${SDKROOT:-}" ]; then
	SDKROOT=$(xcrun --show-sdk-path 2>/dev/null) && export SDKROOT
fi
