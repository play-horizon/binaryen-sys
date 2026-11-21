# The bindgen-cli version and the options of every bindgen run of the repository, sourced by
# scripts/regenerate-bindings.sh (the crate's bindings) and scripts/test-scripts.sh (the fixture of
# scripts/rust-items.awk's tests), so that the fixture is made the way the bindings are. Each run
# adds its header, its allowlist and its output. scripts/check-c-api.sh sources it too: it parses
# binaryen-c.h with clang in the language bindgen does (bindgen_clang_options).
#
# The C API may let a C++ exception (std::bad_alloc) escape, so its functions use the `C-unwind`
# ABI, under which an unwinding call is defined behaviour. Layout tests are left out: they would
# hard-code the sizes of the machine that generated the file. The types come from `core`, so the
# crate is `no_std`.

bindgen_version=0.73.2
bindgen_abi=C-unwind
bindgen_options=(--rust-target 1.85 --rust-edition 2024 --use-core --no-layout-tests --merge-extern-blocks)
bindgen_clang_options=(-x c -std=c11)

# Fails unless the bindgen-cli on PATH is the one above.
require_bindgen() {
	if [[ "$(bindgen --version 2>/dev/null || true)" != "bindgen $bindgen_version" ]]; then
		echo "bindgen-cli $bindgen_version is needed: cargo install bindgen-cli --version $bindgen_version --locked" >&2
		exit 1
	fi
}
