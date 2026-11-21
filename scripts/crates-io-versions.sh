#!/usr/bin/env bash
# Prints the versions of the crate (the one Cargo.toml names) that crates.io has, yanked ones
# included, one per line from the oldest; nothing when crates.io has no version of the crate. It
# reads the crates.io index (https://doc.rust-lang.org/cargo/reference/registry-index.html),
# which lists each published version as a line of JSON, and fails on any other answer, on an
# entry it can't read, and on an answer that lists no version.
#
# It needs cargo, curl and jq, and network access to index.crates.io.
#
# Usage: scripts/crates-io-versions.sh
set -euo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp --directory)"
trap 'rm --recursive --force "$work"' EXIT

cargo metadata --no-deps --format-version 1 --locked >"$work/metadata.json"
name="$(jq --raw-output '.packages[0].name' "$work/metadata.json")"

# The index's path for a name of four characters or more, as the crate's is.
if ((${#name} < 4)); then
	echo "$name is too short for this script's index path" >&2
	exit 1
fi
status="$(curl --silent --show-error --output "$work/index" --write-out '%{http_code}' \
	"https://index.crates.io/${name:0:2}/${name:2:2}/$name")"
case "$status" in
200)
	jq --raw-output \
		'if (.vers | type) == "string" then .vers else error("an entry without a version") end' \
		"$work/index" >"$work/versions"
	if [[ ! -s "$work/versions" ]]; then
		echo "the crates.io index lists no version of $name" >&2
		exit 1
	fi
	sort --version-sort "$work/versions"
	;;
404) ;;
*)
	echo "the crates.io index answered $status for $name" >&2
	exit 1
	;;
esac
