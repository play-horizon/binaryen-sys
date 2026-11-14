#!/usr/bin/env bash
# Moves the crate to a newer Binaryen release: points the `binaryen` submodule at the release's
# tag, regenerates src/bindings.rs (scripts/regenerate-bindings.sh) and sets the crate's version
# to `<release number>.0.0`, in Cargo.toml and Cargo.lock. It commits nothing: the update
# workflow builds and tests the result, then commits and tags it.
#
# Usage: scripts/update-binaryen.sh [version_<N>]
#   With no argument, the latest release tag of WebAssembly/binaryen. It does nothing when the
#   crate is already on that release or a newer one, and prints the tag it moved to otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."

tag="${1:-}"
if [[ -z "$tag" ]]; then
	tag="$(git ls-remote --tags --refs https://github.com/WebAssembly/binaryen.git 'version_*' |
		sed 's|.*refs/tags/||' | grep --extended-regexp '^version_[0-9]+$' |
		sort --field-separator=_ --key=2 --numeric-sort | tail --lines=1)"
fi
if [[ ! "$tag" =~ ^version_([0-9]+)$ ]]; then
	echo "not a Binaryen release tag: '$tag'" >&2
	exit 1
fi
release="${BASH_REMATCH[1]}"

current="$(sed --quiet 's/^version = "\([0-9]*\)\..*"$/\1/p' Cargo.toml | head --lines=1)"
if [[ -n "$current" && "$current" -ge "$release" ]]; then
	echo "already on Binaryen $current, not older than $tag" >&2
	exit 0
fi

git -C binaryen fetch --depth=1 origin "refs/tags/$tag:refs/tags/$tag"
git -C binaryen checkout --detach --quiet "$tag"
scripts/regenerate-bindings.sh
sed "0,/^version = .*/s//version = \"$release.0.0\"/" Cargo.toml >Cargo.toml.new
mv Cargo.toml.new Cargo.toml
cargo update --workspace --quiet
echo "$tag"
