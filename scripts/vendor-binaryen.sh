#!/usr/bin/env bash
# Vendors Binaryen's sources: replaces binaryen/ with the part of a Binaryen release the static
# library build needs, byte for byte as upstream has it, and records the release's tag and commit
# in binaryen-release. With --check, it changes nothing and fails unless binaryen/ is exactly that
# part of the recorded release (the same files, the same bytes, the same executable bits), and the
# recorded tag still names the recorded commit upstream.
#
# It needs git and network access to github.com, and runs no code from Binaryen.
#
# Usage: scripts/vendor-binaryen.sh version_<N>
#        scripts/vendor-binaryen.sh --check
set -euo pipefail

upstream=https://github.com/WebAssembly/binaryen.git

# What the static library build reads (build.rs's CMake options): the top CMakeLists.txt and the
# files it configures unconditionally, the library's sources, and the third-party code it compiles
# (FP16's headers, LLVM's DWARF support). Left out: the tools, binaryen.js, the tests, the fuzzers,
# and the submodules (googletest, fuzztest, mimalloc, the spec test suite), which only the tests,
# the fuzzers and the mimalloc build use. Binaryen's LICENSE, and the licences inside FP16 and
# llvm-project, are part of it. Patterns are git's sparse-checkout patterns (no-cone mode).
subset=(
	/CMakeLists.txt
	/LICENSE
	/config.h.in
	/scripts/binaryen-lit.in
	/src/
	'!/src/js/'
	'!/src/tools/'
	/test/lit/CMakeLists.txt
	/test/lit/lit.site.cfg.py.in
	/third_party/CMakeLists.txt
	/third_party/FP16/
	/third_party/llvm-project/
)

cd "$(dirname "$0")/.."

# The commit `tag` names in WebAssembly/binaryen (the peeled line of an annotated tag comes last).
tag_commit() {
	git ls-remote "$upstream" "refs/tags/$1" "refs/tags/$1^{}" | tail --lines=1 | cut --fields=1
}

# Checks out the subset of `commit`, reached through `tag`, into the new directory `dest`, with no
# .git: a shallow, blobless clone, whose sparse checkout fetches only the subset's files. git
# checks every object it fetches against the commit's id.
fetch_subset() {
	local tag="$1" commit="$2" dest="$3"
	git clone --quiet --depth=1 --filter=blob:none --no-checkout --branch="$tag" "$upstream" "$dest"
	if [[ "$(git -C "$dest" rev-parse HEAD)" != "$commit" ]]; then
		echo "upstream's $tag moved: it isn't $commit any more" >&2
		exit 1
	fi
	git -C "$dest" sparse-checkout set --no-cone "${subset[@]}"
	git -C "$dest" checkout --quiet
	rm -rf "$dest/.git"
}

# One line per file under `dir`: whether it is executable, then its path.
file_modes() {
	(cd "$1" && find . -type f \( -perm -u+x -printf 'x %P\n' -o -printf '- %P\n' \) | LC_ALL=C sort)
}

work="$(mktemp --directory)"
trap 'rm -rf "$work"' EXIT

if [[ "${1:-}" == "--check" ]]; then
	tag="$(sed --quiet 's/^tag //p' binaryen-release)"
	commit="$(sed --quiet 's/^commit //p' binaryen-release)"
	if [[ ! "$tag" =~ ^version_[0-9]+$ || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
		echo "binaryen-release names no release tag and commit" >&2
		exit 1
	fi
	fetch_subset "$tag" "$commit" "$work/binaryen"
	diff --recursive --no-dereference --brief "$work/binaryen" binaryen
	diff <(file_modes "$work/binaryen") <(file_modes binaryen)
	echo "binaryen/ is exactly upstream's $tag ($commit), in the vendored part"
	exit 0
fi

tag="${1:-}"
if [[ ! "$tag" =~ ^version_[0-9]+$ ]]; then
	echo "not a Binaryen release tag: '$tag'" >&2
	exit 1
fi
commit="$(tag_commit "$tag")"
if [[ -z "$commit" ]]; then
	echo "WebAssembly/binaryen has no tag $tag" >&2
	exit 1
fi
fetch_subset "$tag" "$commit" "$work/binaryen"
rm -rf binaryen
cp --recursive --preserve=mode "$work/binaryen" binaryen
cat >binaryen-release <<EOF
# The Binaryen release vendored in binaryen/, written by scripts/vendor-binaryen.sh, which checks
# it with --check.
tag $tag
commit $commit
EOF
