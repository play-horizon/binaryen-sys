#!/usr/bin/env bash
# Fails when a direct dependency of the crate (normal, build or development) has a newer release
# on crates.io than the version Cargo.lock holds, and lists each one with both versions, also in
# the job summary when it runs in GitHub Actions. Yanked releases and pre-releases don't count.
#
# It needs cargo, curl, jq and GNU coreutils, and network access to index.crates.io.
#
# Usage: scripts/check-outdated.sh
set -euo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp --directory)"
trap 'rm --recursive --force "$work"' EXIT

# The root package's direct dependencies, each with its locked version.
cargo metadata --format-version 1 --locked >"$work/metadata.json"
jq --raw-output '
	(.packages | map({key: .id, value: .}) | from_entries) as $packages |
	.resolve.root as $root |
	.resolve.nodes[] | select(.id == $root) | .deps[] |
	$packages[.pkg] | "\(.name) \(.version)"' "$work/metadata.json" | LC_ALL=C sort --unique >"$work/direct"

# The path of a crate's file in the index (https://doc.rust-lang.org/cargo/reference/registry-index.html#index-files).
index_path() {
	local name="${1,,}"
	case "${#name}" in
	1) echo "1/$name" ;;
	2) echo "2/$name" ;;
	3) echo "3/${name:0:1}/$name" ;;
	*) echo "${name:0:2}/${name:2:2}/$name" ;;
	esac
}

outdated=()
while read -r name locked; do
	curl --silent --show-error --fail --output "$work/index" "https://index.crates.io/$(index_path "$name")"
	latest="$(jq --raw-output 'select((.yanked | not) and (.vers | contains("-") | not)) | .vers' "$work/index" |
		sort --version-sort | tail --lines=1)"
	if [[ -z "$latest" ]]; then
		echo "crates.io lists no release of $name" >&2
		exit 1
	fi
	if [[ "$latest" != "$locked" && "$(printf '%s\n' "$locked" "$latest" | sort --version-sort | tail --lines=1)" == "$latest" ]]; then
		outdated+=("| \`$name\` | $locked | $latest |")
	fi
done <"$work/direct"

if ((${#outdated[@]} == 0)); then
	echo "Every direct dependency is on its latest release: $(awk '{printf "%s%s %s", sep, $1, $2; sep=", "}' "$work/direct")."
	exit 0
fi
{
	echo '## Outdated direct dependencies'
	echo
	echo '| Dependency | In Cargo.lock | Latest |'
	echo '|---|---|---|'
	printf '%s\n' "${outdated[@]}"
	echo
	echo 'Raise the requirement in Cargo.toml to the latest release, run `cargo update`, and check that CI passes (CONTRIBUTING.md, "Dependencies").'
} >"$work/summary"
cat "$work/summary" >&2
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	cat "$work/summary" >>"$GITHUB_STEP_SUMMARY"
fi
exit 1
