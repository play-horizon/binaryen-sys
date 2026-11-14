# binaryen-sys

Raw Rust bindings to the **C API** of [Binaryen](https://github.com/WebAssembly/binaryen),
the WebAssembly compiler and optimizer library: every type and function `binaryen-c.h` declares,
on the latest Binaryen release. The crate builds Binaryen from source, as a static library, and
links it in.

## Using it

Depend on a tag of this repository, the latest one for the latest Binaryen release (see
[Versions](#versions)):

```toml
[dependencies]
binaryen-sys = { git = "https://github.com/play-horizon/binaryen-sys.git", tag = "v133.0.0" }
```

Building needs CMake 3.16.3 or later and a C++20 compiler: GCC or Clang on Linux, the Xcode
command-line tools on macOS, Visual Studio's C++ tools on Windows. Cargo fetches the `binaryen`
submodule with the crate. The first build compiles Binaryen, which takes a few minutes; Cargo
reuses it afterwards.

What the build script builds: Binaryen's library only (no tools, no tests), in its release
configuration, with no link-time optimisation, and with Binaryen's assertions kept, as Binaryen
does by default, so that a broken invariant inside it aborts rather than going on. The C++
standard library is linked for the target (libstdc++ on Linux, libc++ on macOS, MSVC's own on
Windows).

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

## Versions

The crate's major version is the number of the Binaryen release it is built on: Binaryen's
`version_133` is the crate's `133.0.0`, tagged `v133.0.0`. A fix of the crate itself, on the same
Binaryen release, bumps the minor or patch version (`133.0.1`), in its own commit, and is tagged
the same way.

`main` is pushed only by the update workflow or in a commit that bumps the crate's version, and
every version on `main` is tagged.

## How a new Binaryen release becomes a tag

`.github/workflows/update.yml` runs every day at 05:23 UTC, and by hand from the Actions tab or
with `gh workflow run update.yml`:

1. **prepare** runs `scripts/update-binaryen.sh`, which finds the latest `version_<N>` tag of
   `WebAssembly/binaryen`. If the crate is already on it, the run ends there. Otherwise the script
   points the `binaryen` submodule at the tag, regenerates `src/bindings.rs`, and sets the
   version to `<N>.0.0` in `Cargo.toml` and `Cargo.lock`; the job commits that as
   `BUILD: Binaryen version_<N>` and pushes it to the branch `update-binaryen`.
2. **test** runs the CI workflow on that commit: the build and the tests on Linux, Windows and
   macOS, and the checks on Linux.
3. **release** fast-forwards `main` to the commit and tags it `v<N>.0.0`, in one atomic push,
   then deletes `update-binaryen`.

If any step fails, `main` and the tags stay as they were, and the next run tries again. A release
that changes the C API in a way the bindings can't express, or that breaks the build, needs a
person: make the fix in a commit on `update-binaryen` (or redo the update by hand, below), check
it, and push it to `main` with the version and the tag the workflow would have given it.

Moving a project that depends on the crate to the new release is a change of tag in that project.

## By hand

The scripts are bash and need, besides Cargo, `git` and network access:

- `scripts/regenerate-bindings.sh` regenerates `src/bindings.rs` from the pinned Binaryen with
  bindgen-cli 0.73.2 (`cargo install bindgen-cli --version 0.73.2 --locked`), which needs libclang
  (on Ubuntu, `libclang-dev`). Every item of `binaryen-c.h` is bound, with the expression ids it
  declares through `wasm-delegations.def`, and nothing from the C headers it includes.
- `scripts/update-binaryen.sh [version_<N>]` does what the workflow's `prepare` does, without
  committing: to the latest release, or to the one named. Then build and test (`cargo test`),
  commit, and tag the commit `v<N>.0.0`.

## Tests and CI

`cargo test` runs the smoke test (`tests/smoke.rs`): a module using Wasm GC and exception handling
(a struct type and an array type from a type builder, `struct.new`, `struct.get`,
`array.new_fixed`, a tag, `throw`, `try_table` with a `catch_all_ref` and a `catch` clause, and
`throw_ref`), built through the C API, validated, and written as text and as a binary; and the
documentation's example.

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests: `cargo test` on Linux,
Windows and macOS, and on Linux the check that `src/bindings.rs` is what
`scripts/regenerate-bindings.sh` generates, `cargo fmt --check`, Clippy (warnings fail) and the
API docs (warnings fail). Its actions are pinned to commit SHAs, with the release in a comment.

## Origin and licence

This crate started from the `binaryen-sys` crate of
[`pepyakin/binaryen-rs`](https://github.com/pepyakin/binaryen-rs), by Sergey Pepyakin, under the
Apache License 2.0. It changed so that it binds the C API (that crate bound only the
functions and types named `Binaryen*`, leaving out the type builder, the Relooper and the
expression runner), follows the latest Binaryen release and updates itself, uses the `C-unwind`
ABI, and dropped the C++ shim (fuzzing and reading helpers that aren't part of the C API) and the
generated list of passes.

Licensed under the Apache License 2.0 ([LICENSE](LICENSE)), like Binaryen itself.
