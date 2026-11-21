#!/usr/bin/env bash
# Prints the commit holding the previous Binaryen release's bindings, then that release's tag
# (`<commit> version_<N>`), for scripts/check-c-api.sh: the newest commit, going back from HEAD
# along the first parents, whose binaryen-release names another release than the working tree's.
# It prints nothing when the walk reaches a commit with no binaryen-release first (the history
# holds no earlier release), and fails in a shallow clone, whose history is cut.
#
# It needs git and the repository's whole history.
#
# Usage: scripts/previous-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
	echo "the repository's whole history is needed (git fetch --unshallow)" >&2
	exit 1
fi

release="$(sed --quiet 's/^tag //p' binaryen-release)"
if [[ -z "$release" ]]; then
	echo "binaryen-release names no release" >&2
	exit 1
fi

work="$(mktemp --directory)"
trap 'rm --recursive --force "$work"' EXIT

git rev-list --first-parent HEAD >"$work/history"
while read -r commit; do
	listed="$(git ls-tree --name-only "$commit" -- binaryen-release)"
	if [[ -z "$listed" ]]; then
		exit 0
	fi
	git show "$commit:binaryen-release" >"$work/release-file"
	tag="$(sed --quiet 's/^tag //p' "$work/release-file")"
	if [[ "$tag" != "$release" ]]; then
		echo "$commit $tag"
		exit 0
	fi
done <"$work/history"
