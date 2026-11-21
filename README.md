# binaryen-sys-next

[![crates.io](https://img.shields.io/crates/v/binaryen-sys-next.svg)](https://crates.io/crates/binaryen-sys-next)
[![docs.rs](https://img.shields.io/docsrs/binaryen-sys-next)](https://docs.rs/binaryen-sys-next)
[![CI](https://github.com/play-horizon/binaryen-sys-next/actions/workflows/ci.yml/badge.svg)](https://github.com/play-horizon/binaryen-sys-next/actions/workflows/ci.yml)

Raw Rust bindings to the **C API** of [Binaryen](https://github.com/WebAssembly/binaryen),
the WebAssembly compiler and optimizer library: every type and function `binaryen-c.h` declares,
but the functions its library doesn't define, on the latest Binaryen release, checked against the
header and the library on every change ([The C API check](#the-c-api-check)). The crate builds
Binaryen from source, as a static library, and links it in. A new Binaryen release becomes a
new version of the crate by itself, tested and published, unless it needs a change of the crate
([How a new Binaryen release becomes a version](#how-a-new-binaryen-release-becomes-a-version)).

## Using it

```toml
[dependencies]
binaryen-sys-next = "<N>"
```

`<N>` is the number of a Binaryen release ([Versions](#versions)): `"133"` is Binaryen's
`version_133`, with every later fix of the crate on that release. Each version is also a tag of
this repository (`v<N>.<x>.<y>`), which a git dependency can name instead.

Building needs CMake 3.16.3 or later and a C++20 compiler: GCC or Clang on Linux, the Xcode
command-line tools on macOS, Visual Studio's C++ tools on Windows. Binaryen's sources come with
the crate ([Vendored sources](#vendored-sources)), so Cargo fetches nothing else. The first build
compiles Binaryen, which takes a few minutes; Cargo reuses it afterwards.

What the build script builds: Binaryen's library only (no tools, no tests), in its release
configuration, with no link-time optimisation, and with Binaryen's assertions kept, as Binaryen
does by default, so that a broken invariant inside it aborts rather than going on. The C++
standard library is linked for the target (libstdc++ on Linux, libc++ on macOS, MSVC's own on
Windows). On docs.rs (`DOCS_RS` set), it builds nothing, since documenting the crate doesn't link
it.

Everything is `unsafe` and follows the contract `binaryen-c.h` documents. Three points of it
matter to any safe wrapper (the crate's documentation says more):

- **Fatal errors end the process**: some misuse (an unknown pass name, an index out of range, a
  binary that doesn't parse) prints a message and calls `_Exit`, and a failed assertion aborts.
- **Global options aren't synchronised**: the `BinaryenSet*` options are process-wide variables,
  which the optimisation and writing functions read.
- **Unwinding**: the functions use the `C-unwind` ABI, so a C++ exception that escapes one (such
  as `std::bad_alloc`) unwinds into the caller as defined behaviour.

The buffers the `*AllocateAndWrite*` functions return are released with the crate's `free`, the
C library's.

## Vendored sources

`binaryen/` holds the part of a Binaryen release that the build script's static library build
reads, byte for byte as Binaryen's repository has it at the release's tag, and nothing else:

- the top `CMakeLists.txt`, `config.h.in`, and the three files that `CMakeLists.txt` reads
  whatever its options: `scripts/binaryen-lit.in`, which it configures, and `test/lit/`'s
  `CMakeLists.txt`, which it adds, with the `lit.site.cfg.py.in` that one configures;
- `src/`, the library's sources, without `src/tools/` (the command-line tools) and `src/js/`
  (binaryen.js);
- `third_party/CMakeLists.txt`, `third_party/FP16/` (half-precision float headers) and
  `third_party/llvm-project/` (the part of LLVM that reads and writes DWARF);
- `LICENSE`, Binaryen's licence (Apache 2.0); FP16's and LLVM's licences and notices are inside
  their directories ([Origin and licence](#origin-and-licence)).

Left out are the tests, the fuzzers, the tools, binaryen.js, the documentation, and Binaryen's own
submodules (googletest, fuzztest, mimalloc, the spec test suite), which only its tests, fuzzers
and mimalloc build use. That is 722 files; the packaged crate is 9.8 MiB, 2.1 MiB compressed. The
list is in `scripts/vendor-binaryen.sh`. `.gitattributes` keeps git from changing the files'
line endings on any platform.

`binaryen-release` records the release: its tag (`version_<N>`) and the commit the tag names in
`WebAssembly/binaryen`. `scripts/vendor-binaryen.sh --check` checks the vendored tree against
them: it fetches that subset of the tag from Binaryen's repository (a shallow, blobless clone,
which fetches only those files, each checked by git against the commit's id), fails if the tag no
longer names the recorded commit, and compares it with `binaryen/`: the same files, the same
bytes, the same executable bits. CI runs it on every push and pull request, and on every update
the workflow makes. Nobody edits `binaryen/` by hand: a fix Binaryen needs goes upstream, and the
crate takes it with the release that has it.

## Versions

The crate's major version is the number of the Binaryen release it is built on: Binaryen's
`version_133` is the crate's `133.0.0`, tagged `v133.0.0`. Each Binaryen release may change the C
API, so moving to the next one is a change of the major version in the dependent's `Cargo.toml`.
A change of the crate itself, on the same Binaryen release, bumps the minor version (the patch
version for a fix that changes nothing else), in its own commit, and is tagged the same way.

`main` is pushed only by the update workflow or in a commit that bumps the crate's version.
Every version on `main` is tagged, and from the crate's first version on crates.io (`133.2.0`) on,
published there; a version whose tagged commit can't be published loses its tag instead
([CONTRIBUTING.md](CONTRIBUTING.md#when-publishing-fails)).

## How a new Binaryen release becomes a version

`.github/workflows/update.yml` runs every day at 05:23 UTC, and by hand from the Actions tab or
with `gh workflow run update.yml`:

1. **prepare** runs `scripts/update-binaryen.sh`, which finds the latest `version_<N>` tag of
   `WebAssembly/binaryen`. If the crate is already on it, the job reports that Binaryen is up to
   date and the update ends there. Otherwise the script vendors the release's sources
   (`scripts/vendor-binaryen.sh version_<N>`, which replaces `binaryen/` and `binaryen-release`),
   regenerates `src/bindings.rs`, and sets the version to `<N>.0.0` in `Cargo.toml` and
   `Cargo.lock`; the job hands on the tag and the new `src/bindings.rs`. It can't write to the
   repository: it builds and runs third-party code (bindgen-cli and its dependencies).
2. **push** writes the same update itself from those two alone, with this repository's scripts,
   git and the toolchain's cargo (no third-party code): it checks the tag names a newer release,
   vendors the release's sources from Binaryen's repository with `scripts/vendor-binaryen.sh`,
   writes the bindings to `src/bindings.rs` (the one file it takes from **prepare**), and sets
   the version. It commits that as `BUILD: Binaryen version_<N>` and pushes it to the branch
   `update-binaryen`, replacing what an earlier run left there, but never a person's commits:
   when the branch holds any (authored or committed by someone else than the workflow), the run
   fails instead.
3. **test** runs the CI workflow on that commit ([Tests and CI](#tests-and-ci)): the build and the
   tests on Linux, Windows and macOS, and the checks on Linux, among them that `binaryen/` is
   exactly the release's sources, that `src/bindings.rs` is what they generate, and that it covers
   the C API exactly ([The C API check](#the-c-api-check)).
4. **release** fast-forwards `main` to the commit and tags it `v<N>.0.0`, in one atomic push,
   then deletes `update-binaryen`.
5. **publish** starts the release workflow on the tag (a tag pushed with a workflow's own token
   starts no workflow by itself).

On every run, beside the update, **republish** checks that crates.io has every tagged version of
`main` from the crate's first one there on (below), and **keepalive** keeps the schedules alive
([Keeping the schedules alive](#keeping-the-schedules-alive)).

`.github/workflows/release.yml` publishes a tagged version on crates.io: the one the update
workflow tags, and one a person tags ([CONTRIBUTING.md](CONTRIBUTING.md#versions-and-releases)).
It checks that the tag names the crate's version on a commit of `main`, runs CI on it (which also
builds the crate from its package, proving the package holds everything the build needs), then
uploads the package, in a job that runs no build. Its upload token comes from crates.io's
[trusted publishing](https://crates.io/docs/trusted-publishing): crates.io gives the run a token
that expires after 30 minutes, for this workflow of this repository in the environment
`crates-io` only, and no token is stored anywhere. A version crates.io already has is left as it
is.

Only **push**, **release**, **publish**, **republish** and **keepalive** hold a token that may
change the repository (the last three only to manage Actions), each in the step that uses it,
with no credential on disk before it; none of them runs third-party code.

If a step up to **test** fails, `main`, the tags and crates.io stay as they were, and the next run
tries again. If publishing fails once a version is tagged (crates.io down, for instance), the next
run publishes it: **republish** starts the release workflow again on each tag of `main` whose
version crates.io lacks, from the crate's first version on crates.io on, unless a release run for
that tag is still going, and fails, so that a person hears of it (a release that keeps failing fails
every update run until a person fixes it, as
[CONTRIBUTING.md](CONTRIBUTING.md#when-publishing-fails) says; `gh workflow run release.yml --ref
v<version>` starts one by hand). A failure of **test** means the release needs a change of the
crate: a function, type or constant the bindings don't cover, a test or a build that breaks, a
hand-written part that no longer matches. Nothing is published until a person makes that change:
[CONTRIBUTING.md](CONTRIBUTING.md#finishing-an-update-by-hand) says how, and how to fix each failure
of the checks.

### The C API check

`scripts/check-c-api.sh` compares three independent listings of the C API: what clang's syntax
tree of `binaryen-c.h` declares (its top-level declarations, enumerators and macros, minus those
of the C headers it includes), what `src/bindings.rs` binds, and what the static library the build
script builds defines (`nm`). It fails, listing the names, when:

- an item the header declares isn't bound, unless `scripts/c-api-unbound.txt` names it with the
  reason (which also keeps bindgen from binding it);
- the bindings have an item the header doesn't declare, or a function the library doesn't define,
  which no call could link;
- `scripts/c-api-unbound.txt` names an item that is bound, isn't declared any more, or is a
  function the library defines;
- the header includes a Binaryen file other than `wasm-delegations.def`, whose items the bindings'
  allowlist would leave out;
- bindgen bound a type as an opaque blob, a layout it couldn't express;
- a function returning a buffer to free (`*AllocateAndWrite*`) isn't named in the documentation
  of the crate's `free`.

Together with the build, the tests, the documentation's example and its links, and the lints
(which fail on a lint expectation the bindings no longer need, or on one they now need), it makes
CI fail whenever a release changes the C API in a way the crate's hand-written parts don't cover.
Binaryen's `version_133` declares four functions its library doesn't define
(`BinaryenStringIterMove`, `BinaryenStringIterNext`, `BinaryenStringSliceIter` and
`BinaryenStringWTF8Advance`), which `scripts/c-api-unbound.txt` lists.

### Keeping the schedules alive

GitHub disables the scheduled workflows of a public repository "when no repository activity has
occurred in 60 days"
([Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)),
and Binaryen releases come about every month or two, so a quiet stretch would pause the updates
and the dependency checks. The workflows make no commit to prevent it: on every run, scheduled or
by hand, the update workflow's **keepalive** job re-enables both scheduled workflows
(`update.yml` and `dependencies.yml`) through the REST API
([Enable a workflow](https://docs.github.com/en/rest/actions/workflows#enable-a-workflow),
`PUT /repos/{owner}/{repo}/actions/workflows/{workflow}/enable`), with a token that may only
manage Actions (`actions: write`, nothing else). It runs beside the update, so a failed update
doesn't stop it.

GitHub's documentation says what the endpoint does (it sets the workflow's state to `active`) but
not which activity resets the 60 days; that re-enabling does is what the projects that keep their
schedules this way report, not something GitHub documents. If the schedule is paused anyway (the
Actions tab says so, and `gh workflow list --all` shows the state `disabled_inactivity`), a
disabled workflow can't run its keepalive: re-enable it from the Actions tab, or with
`gh workflow enable update.yml`, and run it once (`gh workflow run update.yml`) to catch up.

## Dependencies

`deny.toml` configures [cargo-deny](https://github.com/EmbarkStudios/cargo-deny), which CI runs
on every push and pull request, and `.github/workflows/dependencies.yml` every day at 04:41 UTC
(so that an advisory published since the last push shows up): it fails on any crate of
`Cargo.lock` with a known vulnerability (the RustSec advisory database), on a licence that isn't
on its allow-list, and on a crate from anywhere but crates.io. The same daily workflow runs
`scripts/check-outdated.sh`, which fails when a direct dependency (normal, build or development)
has a newer release on crates.io than the version `Cargo.lock` holds, and lists them in the job
summary.

## By hand

The scripts are bash and need, besides Cargo, `git`, network access and GNU coreutils,
diffutils, find, grep and sed (as on Linux):

- `scripts/vendor-binaryen.sh version_<N>` replaces `binaryen/` with that release's sources and
  records it in `binaryen-release`; `scripts/vendor-binaryen.sh --check` checks the vendored tree
  ([Vendored sources](#vendored-sources)).
- `scripts/regenerate-bindings.sh` regenerates `src/bindings.rs` from the vendored Binaryen with
  bindgen-cli 0.73.2 (`cargo install bindgen-cli --version 0.73.2 --locked`), which needs libclang
  (on Ubuntu, `libclang-dev`). Every item of `binaryen-c.h` is bound, with the expression ids it
  declares through `wasm-delegations.def`, but those `scripts/c-api-unbound.txt` names, and
  nothing from the C headers it includes.
- `scripts/update-binaryen.sh [version_<N>]` does what the workflow's `prepare` does, without
  committing: to the latest release, or to the one named.
- `scripts/check-c-api.sh` runs [the C API check](#the-c-api-check); it also needs clang, jq and
  GNU nm.
- `scripts/check-outdated.sh` lists the outdated direct dependencies; it also needs curl and jq.

[CONTRIBUTING.md](CONTRIBUTING.md) says how to check a change before a pull request, and how to
finish an update by hand.

## Tests and CI

`cargo test` runs the smoke test (`tests/smoke.rs`): a module using Wasm GC and exception handling
(a struct type and an array type from a type builder, `struct.new`, `struct.get`,
`array.new_fixed`, a tag, `throw`, `try_table` with a `catch_all_ref` and a `catch` clause, and
`throw_ref`), built through the C API, validated, and written as text and as a binary; and the
documentation's example.

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests: `cargo test` on Linux,
Windows and macOS; on Linux the checks that `binaryen/` is exactly the recorded release's
sources (`scripts/vendor-binaryen.sh --check`), that `src/bindings.rs` is what
`scripts/regenerate-bindings.sh` generates, `cargo fmt --check`, Clippy (warnings fail), the API
docs (warnings fail) and [the C API check](#the-c-api-check); `cargo package`, which builds the
crate from its package; and `cargo deny check` ([Dependencies](#dependencies)). Its actions are
pinned to commit SHAs, with the release in a comment, and the tools it installs to exact versions.

## Origin and licence

This crate started from the `binaryen-sys` crate of
[`pepyakin/binaryen-rs`](https://github.com/pepyakin/binaryen-rs), by Sergey Pepyakin, under the
Apache License 2.0. It changed so that it binds the C API (that crate bound only the
functions and types named `Binaryen*`, leaving out the type builder, the Relooper and the
expression runner), follows the latest Binaryen release and updates itself, uses the `C-unwind`
ABI, and dropped the C++ shim (fuzzing and reading helpers that aren't part of the C API) and the
generated list of passes.

The crate's own code is licensed under the Apache License 2.0 ([LICENSE](LICENSE)), like
Binaryen itself ([binaryen/LICENSE](binaryen/LICENSE)). The vendored sources keep their licences
and notices, as upstream has them:

- Binaryen: Apache 2.0, except its suffix tree (`src/support/suffix_tree*`), which began as LLVM
  code and is under LLVM's licence, Apache 2.0 with LLVM exceptions (in the files).
- FP16: MIT ([binaryen/third_party/FP16/LICENSE](binaryen/third_party/FP16/LICENSE)).
- LLVM's DWARF support (`binaryen/third_party/llvm-project/`): Apache 2.0 with LLVM exceptions,
  the project's licence, which also gives the legacy University of Illinois/NCSA licence its older
  code came under ([include/llvm/LICENSE.TXT](binaryen/third_party/llvm-project/include/llvm/LICENSE.TXT));
  the NCSA licence too for its system interface code (`Unix/`,
  [include/llvm/Support/LICENSE.TXT](binaryen/third_party/llvm-project/include/llvm/Support/LICENSE.TXT));
  Unicode's licence too for its UTF conversions (in `ConvertUTF.cpp` and
  `include/llvm/Support/ConvertUTF.h`); and its MD5 (`MD5.cpp`, `include/llvm/Support/MD5.h`) is
  in the public domain, with a permissive grant where that doesn't hold (in the files).

The library the crate links in is made of all of them, which `Cargo.toml`'s `license` states as
`Apache-2.0 AND Apache-2.0 WITH LLVM-exception AND NCSA AND Unicode-DFS-2015 AND MIT` (SPDX has no
identifier for `MD5.cpp`'s notice, which asks nothing of the user).
