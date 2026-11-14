#!/usr/bin/env bash
# Regenerates src/bindings.rs, the bindings to every type and function `binaryen-c.h` declares,
# from the vendored Binaryen sources (binaryen/), with bindgen-cli at the version below
# (it needs libclang). CI runs it and fails when the checked-in file differs.
#
# Usage: scripts/regenerate-bindings.sh
set -euo pipefail

bindgen_version=0.73.2

cd "$(dirname "$0")/.."
if [[ "$(bindgen --version 2>/dev/null || true)" != "bindgen $bindgen_version" ]]; then
	echo "bindgen-cli $bindgen_version is needed: cargo install bindgen-cli --version $bindgen_version --locked" >&2
	exit 1
fi

# Every item declared in binaryen-c.h (with the expression ids it declares by including
# wasm-delegations.def), and nothing from the C headers it includes. The C API may
# let a C++ exception (std::bad_alloc) escape, so its functions use the `C-unwind` ABI, under which
# an unwinding call is defined behaviour. Layout tests are left out: they would hard-code the
# sizes of the machine that generated the file. The types come from `core`, so the crate is
# `no_std`.
bindgen binaryen/src/binaryen-c.h \
	--allowlist-file '.*binaryen-c\.h' \
	--allowlist-file '.*wasm-delegations\.def' \
	--override-abi '.*=C-unwind' \
	--rust-target 1.85 \
	--rust-edition 2024 \
	--use-core \
	--no-layout-tests \
	--merge-extern-blocks \
	--output src/bindings.rs \
	-- -x c -std=c11
