#!/usr/bin/env bash
# Checks that the crate covers the C API of the vendored Binaryen (binaryen/), with nothing
# missing and nothing extra, so that no version of the crate leaves out part of it. It fails, and
# lists what to fix (CONTRIBUTING.md, "When a check fails"), when:
#
# - binaryen-c.h includes a Binaryen file other than wasm-delegations.def, whose items the
#   bindings' allowlist (scripts/regenerate-bindings.sh) wouldn't take;
# - an item binaryen-c.h declares (a function, type, struct, union, enum, enumerator, variable or
#   macro) isn't in src/bindings.rs, unless scripts/c-api-unbound.txt names it with the reason;
# - src/bindings.rs has an item binaryen-c.h doesn't declare, or a function the static library
#   doesn't define (a call to it would fail to link);
# - scripts/c-api-unbound.txt names an item that is bound, that binaryen-c.h doesn't declare, or
#   a function the library defines (a function is left out only when calling it couldn't link);
# - bindgen bound a type as an opaque blob (a layout it couldn't express);
# - a function returning a buffer to free (`*AllocateAndWrite*`) isn't named in the documentation
#   of the crate's `free` (src/lib.rs);
# - an item of the previous Binaryen release's bindings is gone, or changed, unless
#   scripts/c-api-changes.txt lists it for this release (a maintainer reviewed it), or that file
#   lists, for this release, an item that isn't such a change, or holds a line it can't read.
#
# The declarations come from clang's syntax tree of binaryen-c.h, independently of bindgen: its
# top-level ones, minus those of the C headers it includes (a file of those includes alone, parsed
# the same way). The library's functions come from `nm` on the static library the build script
# builds. The previous release's bindings come from the git history (scripts/previous-release.sh):
# src/bindings.rs at the newest commit, going back from HEAD along the first parents, whose
# binaryen-release names another release (none when the walk reaches a commit with no
# binaryen-release first), compared item by item with the current ones (scripts/rust-items.awk),
# so what bindgen computes counts (layouts, enumerator values, bit-field widths, the ABI) and what
# doesn't change the API doesn't (parameter names, documentation). CI runs it after regenerating
# the bindings, so the update workflow runs it on every new Binaryen release.
#
# It needs clang (or the one $CLANG names), jq, GNU nm, GNU awk (gawk), git with the repository's
# whole history, and the coreutils, on Linux, and runs the crate's build script (`cargo check`).
#
# Usage: scripts/check-c-api.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# The check parses binaryen-c.h in the language bindgen does (bindgen_clang_options).
source scripts/bindgen-options.sh

clang="${CLANG:-clang}"
for tool in "$clang" jq nm gawk git cargo; do
	if ! command -v "$tool" >/dev/null; then
		echo "$tool is needed and wasn't found" >&2
		exit 1
	fi
done
header=binaryen/src/binaryen-c.h
bindings=src/bindings.rs
unbound_list=scripts/c-api-unbound.txt
changes_list=scripts/c-api-changes.txt
# The Binaryen files the bindings take items from besides binaryen-c.h, as the allowlist of
# scripts/regenerate-bindings.sh names them.
allowlisted_includes=(binaryen/src/wasm-delegations.def)

work="$(mktemp --directory)"
trap 'rm --recursive --force "$work"' EXIT

# `grep`, for which finding no line isn't an error (it exits with 1 then, and 2 on an error).
filter() {
	grep "$@" || (($? == 1))
}

# The sorted lines of the file `$1` that aren't in the sorted file `$2`.
lines_not_in() {
	LC_ALL=C comm -23 "$1" "$2"
}

problems=0
# Reports one problem when the file `$2` lists names: the title `$1`, then the names.
report() {
	local title="$1" names="$2"
	if [[ ! -s "$names" ]]; then
		return
	fi
	problems=$((problems + 1))
	{
		echo "$title:"
		sed 's/^/  /' "$names"
	} >>"$work/report"
}

# The files binaryen-c.h includes: `-H` prints each one, after one dot per level of nesting.
if ! "$clang" "${bindgen_clang_options[@]}" -fsyntax-only -H "$header" 2>"$work/includes"; then
	cat "$work/includes" >&2
	exit 1
fi
binaryen_root="$(realpath binaryen)"
sed --quiet 's/^\.\+ //p' "$work/includes" | xargs --no-run-if-empty realpath >"$work/included-paths"
filter --fixed-strings "$binaryen_root/" "$work/included-paths" | sed "s|^$binaryen_root/|binaryen/|" |
	LC_ALL=C sort --unique >"$work/binaryen-includes"
printf '%s\n' "${allowlisted_includes[@]}" | LC_ALL=C sort --unique >"$work/allowlisted-includes"
lines_not_in "$work/binaryen-includes" "$work/allowlisted-includes" >"$work/includes-left-out"
report "Binaryen files binaryen-c.h includes that the bindings' allowlist leaves out (scripts/regenerate-bindings.sh)" \
	"$work/includes-left-out"

# The baseline: the C headers binaryen-c.h includes directly (those of its `#include <...>` lines
# that the preprocessor took), alone.
sed --quiet 's/^\. //p' "$work/includes" >"$work/direct-includes"
sed --quiet 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*<\([^>]*\)>.*/\1/p' "$header" >"$work/system-headers"
while read -r name; do
	if grep --quiet --fixed-strings "/$name" "$work/direct-includes"; then
		echo "#include <$name>"
	fi
done <"$work/system-headers" >"$work/baseline.h"

# Writes to `$2` one line per top-level named declaration of the file `$1`, and per enumerator of
# a top-level enum (named or not): its kind, then its name. Then one line per macro: `macro
# <name>` or `function-like-macro <name>`.
declarations() {
	"$clang" "${bindgen_clang_options[@]}" -fsyntax-only -Xclang -ast-dump=json "$1" >"$work/ast.json"
	jq --raw-output '.inner[] | select(.isImplicit | not) |
		(select(.name != null) | "\(.kind) \(.name)"),
		(select(.kind == "EnumDecl") | .inner[]? | select(.kind == "EnumConstantDecl") |
			"EnumConstantDecl \(.name)")' \
		"$work/ast.json" >"$work/declarations"
	"$clang" "${bindgen_clang_options[@]}" -E -dM "$1" >"$work/macros"
	sed --quiet 's/^#define \([A-Za-z_][A-Za-z0-9_]*\)(.*/function-like-macro \1/p;
		s/^#define \([A-Za-z_][A-Za-z0-9_]*\)\( .*\)\?$/macro \1/p' "$work/macros" >>"$work/declarations"
	LC_ALL=C sort --unique "$work/declarations" >"$2"
}
declarations "$header" "$work/header-declarations"
declarations "$work/baseline.h" "$work/baseline-declarations"
lines_not_in "$work/header-declarations" "$work/baseline-declarations" >"$work/c-declarations"

awk '$1 !~ /^(FunctionDecl|TypedefDecl|RecordDecl|EnumDecl|EnumConstantDecl|VarDecl|macro|function-like-macro)$/' \
	"$work/c-declarations" >"$work/unknown-kinds"
report "Declarations of a kind this check doesn't know (scripts/check-c-api.sh)" "$work/unknown-kinds"

# The C functions; then the other C items, each with the pattern of the Rust name bindgen gives
# it: its own, or for an enumerator, its own after its enum's name or typedef's and `_`.
awk '$1 == "FunctionDecl" {print $2}' "$work/c-declarations" | LC_ALL=C sort --unique >"$work/c-functions"
awk '$1 != "FunctionDecl" {print $2, ($1 == "EnumConstantDecl") ? "([A-Za-z0-9_]+_)?" $2 : $2}' \
	"$work/c-declarations" >"$work/c-items"
awk '{print $1}' "$work/c-items" | LC_ALL=C sort --unique >"$work/c-names"
awk '{print $2}' "$work/c-items" >"$work/c-patterns"

sed --quiet 's/^[[:space:]]*pub fn \([A-Za-z0-9_]*\).*/\1/p' "$bindings" | LC_ALL=C sort --unique >"$work/rust-functions"
sed --quiet 's/^[[:space:]]*pub \(type\|struct\|union\|enum\|const\|static\( mut\)\?\) \([A-Za-z0-9_]*\).*/\3/p' "$bindings" |
	filter --invert-match --extended-regexp '(^|_)_bindgen_ty_[0-9]+$' | LC_ALL=C sort --unique >"$work/rust-items"

filter --invert-match '^[[:space:]]*\(#\|$\)' "$unbound_list" | awk '{print $1}' |
	LC_ALL=C sort --unique >"$work/unbound"

while read -r name pattern; do
	if ! grep --quiet --extended-regexp --line-regexp "$pattern" "$work/rust-items"; then
		echo "$name"
	fi
done <"$work/c-items" | LC_ALL=C sort --unique >"$work/c-names-not-bound"

lines_not_in "$work/c-functions" "$work/rust-functions" >>"$work/c-names-not-bound"
LC_ALL=C sort --unique --output="$work/c-names-not-bound" "$work/c-names-not-bound"

lines_not_in "$work/c-names-not-bound" "$work/unbound" >"$work/missing"
report "Declared by binaryen-c.h but not in src/bindings.rs (nor in scripts/c-api-unbound.txt)" "$work/missing"

{
	lines_not_in "$work/rust-functions" "$work/c-functions"
	filter --invert-match --extended-regexp --line-regexp --file="$work/c-patterns" "$work/rust-items"
} >"$work/extra"
report "In src/bindings.rs but not declared by binaryen-c.h" "$work/extra"

lines_not_in "$work/unbound" "$work/c-names-not-bound" >"$work/stale"
report "In scripts/c-api-unbound.txt but bound, or not declared by binaryen-c.h" "$work/stale"

filter --only-matching '[A-Za-z0-9_]*_bindgen_opaque_blob[A-Za-z0-9_]*' "$bindings" |
	LC_ALL=C sort --unique >"$work/opaque"
report "Types bindgen bound as opaque blobs (a layout it couldn't express)" "$work/opaque"

filter 'AllocateAndWrite' "$work/rust-functions" | while read -r name; do
	if ! grep --quiet --fixed-strings "[\`$name\`]" src/lib.rs; then
		echo "$name"
	fi
done >"$work/undocumented-buffers"
report "Functions returning a buffer to free that the documentation of \`free\` (src/lib.rs) doesn't name" \
	"$work/undocumented-buffers"

# The previous release's bindings: the commit scripts/previous-release.sh finds, if any.
release="$(sed --quiet 's/^tag //p' binaryen-release)"
scripts/previous-release.sh >"$work/previous-release"
previous_commit=""
previous_release=""
if [[ -s "$work/previous-release" ]]; then
	read -r previous_commit previous_release <"$work/previous-release"
fi

# The reviewed changes: one `release version_<N>` line, then `removed <name> <what was checked>`
# or `changed <name> <what was checked>` lines, one per name; those of another release don't
# count.
filter --invert-match '^[[:space:]]*\(#\|$\)' "$changes_list" >"$work/changes-lines"
gawk '
	$1 == "release" && NF == 2 && $2 ~ /^version_[0-9]+$/ && !seen_release {seen_release = 1; next}
	seen_release && ($1 == "removed" || $1 == "changed") && NF >= 3 && !($2 in names) {names[$2]; next}
	{print}' "$work/changes-lines" >"$work/malformed-changes"
report "Lines of scripts/c-api-changes.txt it can't read (one \`release version_<N>\` line, then one \`removed\` or \`changed\` line per name, with what was checked)" \
	"$work/malformed-changes"
if [[ "$(gawk '$1 == "release" {print $2; exit}' "$work/changes-lines")" == "$release" ]]; then
	gawk '$1 == "removed" || $1 == "changed" {print $1, $2}' "$work/changes-lines" | LC_ALL=C sort --unique >"$work/reviewed"
else
	: >"$work/reviewed"
fi

# One line per change: `removed <name>` or `changed <name>`, a tab, then the old text and, for a
# change, the new one. A bindings file scripts/rust-items.awk can't read is reported instead.
: >"$work/changes"
: >"$work/unreadable"
if [[ -z "$previous_commit" ]]; then
	echo "No earlier Binaryen release in the history: no bindings to compare with."
else
	git show "$previous_commit:$bindings" >"$work/previous-bindings.rs"
	if ! gawk --assign=source="$previous_commit:$bindings ($previous_release)" --file=scripts/rust-items.awk \
		"$work/previous-bindings.rs" >"$work/previous-items" 2>"$work/parse-error"; then
		cat "$work/parse-error" >>"$work/unreadable"
	fi
	if ! gawk --file=scripts/rust-items.awk "$bindings" >"$work/current-items" 2>"$work/parse-error"; then
		cat "$work/parse-error" >>"$work/unreadable"
	fi
	if [[ ! -s "$work/unreadable" ]]; then
		gawk --field-separator='\t' '
			FILENAME == ARGV[1] {current[$1] = $2; next}
			!($1 in current) {print "removed " $1 "\t" $2; next}
			current[$1] != $2 {print "changed " $1 "\t" $2 "  ->  " current[$1]}' \
			"$work/current-items" "$work/previous-items" | LC_ALL=C sort >"$work/changes"
	fi
fi
report "Bindings scripts/rust-items.awk can't read, so the C API changes aren't known" "$work/unreadable"
while IFS=$'\t' read -r change detail; do
	if ! grep --quiet --fixed-strings --line-regexp "$change" "$work/reviewed"; then
		printf '%s\n    %s\n' "$change" "$detail"
	fi
done <"$work/changes" >"$work/unreviewed"
report "Items of the bindings of ${previous_release:-the previous release} removed or changed in $release that scripts/c-api-changes.txt doesn't list for $release" \
	"$work/unreviewed"
cut --fields=1 "$work/changes" | LC_ALL=C sort --unique >"$work/changed-names"
if [[ -s "$work/unreadable" ]]; then
	: >"$work/stale-changes"
else
	lines_not_in "$work/reviewed" "$work/changed-names" >"$work/stale-changes"
fi
report "In scripts/c-api-changes.txt for $release, but not an item of the bindings removed or changed in $release" \
	"$work/stale-changes"

# The library the build script builds, found through Cargo's report of the build script's run
# (`cargo check` runs it, as a build does, and prints the compiler's messages).
cargo metadata --no-deps --format-version 1 >"$work/metadata.json"
package_id="$(jq --raw-output '.packages[0].id' "$work/metadata.json")"
cargo check --locked --quiet --message-format=json-render-diagnostics >"$work/build.json"
out_dir="$(jq --raw-output --arg id "$package_id" \
	'select(.reason == "build-script-executed" and .package_id == $id) | .out_dir' "$work/build.json")"
library="$out_dir/lib/libbinaryen.a"
if [[ ! -f "$library" ]]; then
	echo "the build script built no $library" >&2
	exit 1
fi
nm --defined-only --extern-only --format=posix "$library" 2>/dev/null >"$work/symbols" || true
awk '$2 == "T" || $2 == "W" {print $1}' "$work/symbols" | LC_ALL=C sort --unique >"$work/library-functions"
if [[ ! -s "$work/library-functions" ]]; then
	echo "nm listed no function in $library" >&2
	exit 1
fi
lines_not_in "$work/rust-functions" "$work/library-functions" >"$work/undefined"
report "Functions in src/bindings.rs that the library doesn't define" "$work/undefined"
LC_ALL=C comm -12 "$work/unbound" "$work/library-functions" >"$work/defined-but-unbound"
report "Functions in scripts/c-api-unbound.txt that the library defines" "$work/defined-but-unbound"

if ((problems > 0)); then
	cat "$work/report" >&2
	echo "The crate doesn't cover the C API exactly: CONTRIBUTING.md, \"When a check fails\", says how to fix each problem." >&2
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		{
			echo '## The C API check failed'
			echo
			echo 'CONTRIBUTING.md, "When a check fails", says how to fix each problem.'
			echo
			echo '```'
			cat "$work/report"
			echo '```'
		} >>"$GITHUB_STEP_SUMMARY"
	fi
	exit 1
fi
echo "src/bindings.rs covers the C API of binaryen-c.h: $(wc --lines <"$work/rust-functions") functions and $(wc --lines <"$work/rust-items") other items, each function defined by the library"
