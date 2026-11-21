#!/usr/bin/env bash
# Regenerates src/bindings.rs, the bindings to every item `binaryen-c.h` declares but those
# scripts/c-api-unbound.txt names, from the vendored Binaryen sources (binaryen/), with bindgen-cli
# at the version and with the options of scripts/bindgen-options.sh (it needs libclang). CI runs it
# and fails when the checked-in file differs.
#
# Usage: scripts/regenerate-bindings.sh
set -euo pipefail

if (($# > 0)); then
	echo "usage: scripts/regenerate-bindings.sh" >&2
	exit 1
fi

cd "$(dirname "$0")/.."
source scripts/bindgen-options.sh
require_bindgen

# The items scripts/c-api-unbound.txt names, which the bindings leave out.
blocklist=()
while read -r name _; do
	blocklist+=(--blocklist-item "$name")
done < <(grep --invert-match '^[[:space:]]*\(#\|$\)' scripts/c-api-unbound.txt)

# Every item declared in binaryen-c.h (with the expression ids it declares by including
# wasm-delegations.def), but those of scripts/c-api-unbound.txt, and nothing from the C headers
# it includes.
bindgen binaryen/src/binaryen-c.h \
	--allowlist-file '.*binaryen-c\.h' \
	--allowlist-file '.*wasm-delegations\.def' \
	"${blocklist[@]}" \
	--override-abi ".*=$bindgen_abi" \
	"${bindgen_options[@]}" \
	--output src/bindings.rs \
	-- "${bindgen_clang_options[@]}"
