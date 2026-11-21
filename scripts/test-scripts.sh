#!/usr/bin/env bash
# The tests of the scripts the C API check is made of, which CI runs in its checks job:
#
# - scripts/rust-items.awk on the fixture scripts/tests/rust-items/: bindings.rs must be
#   bindgen's output for bindings.h, and its items exactly expected.txt, a snapshot reviewed like
#   code. Then each case of cases/ changes bindings.h (`<case>.patch`) or bindgen's ABI
#   (`<case>.abi`), and the items of bindgen's new output that differ must be exactly the ones
#   `<case>.changed` names, by hand (none when the change doesn't touch the API).
# - scripts/previous-release.sh on a history the test makes: which commit holds the previous
#   release's bindings, along the first parents, past a merge from another release, past a change
#   of binaryen-release that keeps its tag, up to a commit with none, from a committed or an
#   uncommitted release, and its refusals.
#
# With --regenerate, it writes bindings.rs again from bindings.h instead (after a change of the
# header, of bindgen-cli's version or of the options of scripts/bindgen-options.sh), and tests
# nothing.
#
# It needs bash, git, bindgen-cli at the version of scripts/bindgen-options.sh (with libclang),
# GNU awk (gawk), patch, diffutils, grep, sed and the coreutils.
#
# Usage: scripts/test-scripts.sh [--regenerate]
set -euo pipefail

if (($# > 1)) || [[ $# == 1 && "$1" != "--regenerate" ]]; then
	echo "usage: scripts/test-scripts.sh [--regenerate]" >&2
	exit 1
fi

cd "$(dirname "$0")/.."
source scripts/bindgen-options.sh
require_bindgen

work="$(mktemp --directory)"
trap 'rm --recursive --force "$work"' EXIT

fixture=scripts/tests/rust-items

# Writes to `$2` bindgen's output for the header `$1`, with the options of
# scripts/bindgen-options.sh and the ABI `$3`.
generate() {
	bindgen "$1" --allowlist-file '.*bindings\.h' --override-abi ".*=$3" "${bindgen_options[@]}" \
		--output "$2" -- "${bindgen_clang_options[@]}"
}

if [[ "${1:-}" == "--regenerate" ]]; then
	generate "$fixture/bindings.h" "$fixture/bindings.rs" "$bindgen_abi"
	exit 0
fi

failures=0
pass() {
	echo "ok: $1"
}
fail() {
	echo "FAILED: $1" >&2
	failures=$((failures + 1))
}

# scripts/rust-items.awk on the file `$1`, named `$3` in its messages, into `$2`, its messages kept
# in `$work/items-error`. A reader that loops forever fails after a minute per file rather than at
# the end of CI's job.
items() {
	timeout 60 gawk --assign=source="$3" --file=scripts/rust-items.awk "$1" >"$2" 2>"$work/items-error"
}

generate "$fixture/bindings.h" "$work/bindings.rs" "$bindgen_abi"
if diff --unified "$fixture/bindings.rs" "$work/bindings.rs" >"$work/fixture.diff"; then
	pass "bindings.rs is bindgen's output for bindings.h"
else
	cat "$work/fixture.diff" >&2
	fail "bindings.rs isn't bindgen's output for bindings.h: scripts/test-scripts.sh --regenerate"
fi

# Without the fixture's items, no other test of rust-items.awk can run.
if ! items "$fixture/bindings.rs" "$work/items" "$fixture/bindings.rs"; then
	cat "$work/items-error" >&2
	echo "FAILED: rust-items.awk can't read the fixture's bindings.rs (or ran for more than a minute)" >&2
	exit 1
fi
# The cases are compared with bindgen's output of this run, so that only their change shows.
if ! items "$work/bindings.rs" "$work/generated-items" "bindgen's output for bindings.h"; then
	cat "$work/items-error" >&2
	echo "FAILED: rust-items.awk can't read bindgen's output for bindings.h (or ran for more than a minute)" >&2
	exit 1
fi
if diff --unified "$fixture/expected.txt" "$work/items" >"$work/snapshot.diff"; then
	pass "rust-items.awk reads the fixture as expected.txt"
else
	cat "$work/snapshot.diff" >&2
	fail "rust-items.awk reads the fixture differently from expected.txt"
fi

# The names whose line differs between the items `$1` and `$2`, or that only one of them has.
changed_names() {
	gawk --field-separator='\t' '
		FILENAME == ARGV[1] {before[$1] = $2; next}
		{after[$1] = $2}
		END {
			for (name in before) if (!(name in after) || before[name] != after[name]) print name
			for (name in after) if (!(name in before)) print name
		}' "$1" "$2" | LC_ALL=C sort
}

# The cases: every file of cases/ is a case's `.changed`, `.patch` or `.abi`, and every case has
# its `.changed` file, and a `.patch` or an `.abi` (or both).
shopt -s dotglob nullglob
: >"$work/case-names"
for case_file in "$fixture"/cases/*; do
	file_name="$(basename "$case_file")"
	case_name="${file_name%.*}"
	case "$file_name" in
	?*.changed | ?*.patch | ?*.abi) echo "$case_name" >>"$work/case-names" ;;
	*) fail "cases/$file_name is no case's .changed, .patch or .abi" ;;
	esac
done
shopt -u dotglob nullglob
LC_ALL=C sort --unique --output="$work/case-names" "$work/case-names"
if [[ ! -s "$work/case-names" ]]; then
	fail "cases/ is missing or holds no case"
fi
while IFS= read -r case_name; do
	case_path="$fixture/cases/$case_name"
	if [[ ! -f "$case_path.changed" ]]; then
		fail "case $case_name has no $case_name.changed"
		continue
	fi
	if [[ ! -f "$case_path.patch" && ! -f "$case_path.abi" ]]; then
		fail "case $case_name has neither $case_name.patch nor $case_name.abi"
		continue
	fi
	cp "$fixture/bindings.h" "$work/bindings.h"
	if [[ -f "$case_path.patch" ]] &&
		! patch --silent --batch --forward --fuzz=0 --reject-file=- "$work/bindings.h" "$case_path.patch" \
			>"$work/patch-output" 2>&1; then
		cat "$work/patch-output" >&2
		fail "case $case_name: $case_name.patch doesn't apply to bindings.h"
		continue
	fi
	abi="$bindgen_abi"
	if [[ -f "$case_path.abi" ]]; then
		abi="$(cat "$case_path.abi")"
	fi
	if ! generate "$work/bindings.h" "$work/case.rs" "$abi" 2>"$work/bindgen-output"; then
		cat "$work/bindgen-output" >&2
		fail "case $case_name: bindgen fails on it (its patch, or the ABI '$abi')"
		continue
	fi
	if ! items "$work/case.rs" "$work/case-items" "bindgen's output for case $case_name"; then
		cat "$work/items-error" >&2
		fail "case $case_name: rust-items.awk can't read bindgen's output for it (or ran for more than a minute)"
		continue
	fi
	changed_names "$work/generated-items" "$work/case-items" >"$work/case-changed"
	if diff --unified "$case_path.changed" "$work/case-changed" >"$work/case.diff"; then
		pass "case $case_name changes exactly the items $case_name.changed names"
	else
		cat "$work/case.diff" >&2
		fail "case $case_name changes other items than $case_name.changed names"
	fi
done <"$work/case-names"

# A history for scripts/previous-release.sh, built with none of the user's or the system's git
# configuration, and none of the git variables of the environment (a hook's GIT_DIR would point
# the commits at another repository):
# version_0, then a commit with no binaryen-release, then version_1 (four commits: one changes the
# file but not its tag, and the last one doesn't touch it), then version_2 (two commits), then a
# merge whose second parent is on version_9, which the walk along the first parents never reaches.
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
history="$work/history"
git init --quiet --template= --initial-branch=main "$history"
mkdir "$history/scripts"
cp scripts/previous-release.sh "$history/scripts/"
commit() {
	git -C "$history" add --all
	git -C "$history" -c user.name=test -c user.email=test@example.invalid commit --quiet --message="$1"
	git -C "$history" rev-parse HEAD
}
release_file() {
	printf 'tag %s\ncommit %s\n' "$1" "$2" >"$history/binaryen-release"
}
release_file version_0 0000
commit "version_0" >/dev/null
rm "$history/binaryen-release"
echo first >"$history/notes"
commit "no release" >/dev/null
release_file version_1 aaaa
version_1_first="$(commit "version_1")"
echo second >>"$history/notes"
commit "version_1, a fix" >/dev/null
release_file version_1 bbbb
commit "version_1, binaryen-release changed, its tag kept" >/dev/null
echo fourth >>"$history/notes"
version_1_last="$(commit "version_1, a later fix")"
release_file version_2 cccc
commit "version_2" >/dev/null
echo fifth >>"$history/notes"
commit "version_2, a fix" >/dev/null
git -C "$history" switch --quiet --create side
release_file version_9 dddd
commit "version_9, on a side branch" >/dev/null
git -C "$history" switch --quiet main
git -C "$history" -c user.name=test -c user.email=test@example.invalid merge --quiet --strategy=ours \
	--message="merge of the side branch" side
merge="$(git -C "$history" rev-parse HEAD)"

# Checks that scripts/previous-release.sh, run in the history at its state, prints `$2`.
expect_previous() {
	local description="$1" expected="$2" printed
	if ! printed="$("$history/scripts/previous-release.sh" 2>"$work/previous-error")"; then
		cat "$work/previous-error" >&2
		fail "previous-release.sh failed: $description"
		return
	fi
	if [[ "$printed" == "$expected" ]]; then
		pass "previous-release.sh: $description"
	else
		fail "previous-release.sh: $description: printed '$printed', expected '$expected'"
	fi
}
expect_previous "the last commit of the previous release, past a merge's second parent" \
	"$version_1_last version_1"
git -C "$history" checkout --quiet "$version_1_last"
expect_previous "nothing past a change of binaryen-release that keeps its tag, nor past a commit with none" ""
git -C "$history" checkout --quiet "$version_1_first"
expect_previous "nothing when the history holds no earlier release since its last commit with none" ""
git -C "$history" checkout --quiet main
release_file version_3 eeee
expect_previous "the last committed release, for an uncommitted new one" "$merge version_2"
git -C "$history" checkout --quiet -- binaryen-release

# Checks that scripts/previous-release.sh, run from `$1`, fails with a message holding `$2`.
expect_refusal() {
	local checkout="$1" message="$2" description="$3"
	if "$checkout/scripts/previous-release.sh" >/dev/null 2>"$work/refusal"; then
		fail "previous-release.sh accepts $description"
	elif grep --quiet --fixed-strings "$message" "$work/refusal"; then
		pass "previous-release.sh refuses $description"
	else
		fail "previous-release.sh refuses $description with another message: $(cat "$work/refusal")"
	fi
}
: >"$history/binaryen-release"
expect_refusal "$history" "binaryen-release names no release" "a binaryen-release that names no release"
git -C "$history" checkout --quiet -- binaryen-release
git clone --quiet --depth=1 "file://$history" "$work/shallow"
expect_refusal "$work/shallow" "whole history is needed" "a shallow clone"

if ((failures > 0)); then
	echo "$failures script tests failed" >&2
	exit 1
fi
echo "Every script test passed."
