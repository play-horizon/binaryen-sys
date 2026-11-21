# Contributing to binaryen-sys-next

The crate is raw bindings to the C API of Binaryen, generated, checked and released by scripts
and workflows ([README.md](README.md)). Most of it is never edited by hand:

- `binaryen/` is exactly a Binaryen release's sources, written by `scripts/vendor-binaryen.sh`. A
  fix Binaryen needs goes [upstream](https://github.com/WebAssembly/binaryen), and the crate takes
  it with the release that has it.
- `src/bindings.rs` is what `scripts/regenerate-bindings.sh` generates. A change of the bindings
  is a change of that script, then a regeneration.

The hand-written parts are `src/lib.rs` (the crate's documentation, the lint expectations on the
bindings, the declaration of `free`), `build.rs`, the tests in `tests/`, the scripts, the
workflows and the documentation.

## Setting up

- Rust: `rust-toolchain.toml` pins the toolchain, which rustup installs by itself.
- CMake 3.16.3 or later and a C++20 compiler, to build Binaryen.
- For the scripts (Linux): bash, git, GNU coreutils, diffutils, find, grep and sed, and libclang
  (on Ubuntu, `libclang-dev`).
- bindgen-cli 0.73.2: `cargo install bindgen-cli --version 0.73.2 --locked`.

## Checking a change

CI runs all of these on every pull request ([README.md](README.md#tests-and-ci)); run them before
opening one:

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- --deny warnings
cargo test --locked
RUSTDOCFLAGS='-D warnings' cargo doc --locked --no-deps
scripts/vendor-binaryen.sh --check
scripts/regenerate-bindings.sh && git diff --exit-code src/bindings.rs
```

Commit subjects are `TYPE: summary`, under 50 characters, with one of the types `FEAT`, `FIX`,
`DOCS`, `STYLE`, `REFACTOR`, `PERF`, `TEST`, `BUILD`, `CI` and `CHORE`; a body only when the change
needs explaining. One commit is one focused change. The documentation changes in the same commit
as what it describes.

## Versions and releases

The version scheme is in [README.md](README.md#versions): the major version is the Binaryen
release, and a change of the crate on the same release bumps the minor or patch version. `main`
is pushed only by the update workflow or in a commit that bumps the version: a change reaches
`main` as a branch whose last commit is `BUILD: version <version>` (the version in `Cargo.toml`
and `Cargo.lock`, with `cargo update --workspace`). Once that commit is on `main` and CI has
passed on it, tag it and push the tag:

```sh
git tag v<version> <commit>
git push origin v<version>
```

## When a check fails

When CI fails on a new Binaryen release (the update workflow's **test** job), the release needs a
change of the crate, made on the update's branch ([Finishing an update by hand](#finishing-an-update-by-hand)).
What to do for each failure:

- **The build fails**: Binaryen's build reads a file the vendored subset leaves out (add it to
  the `subset` of `scripts/vendor-binaryen.sh` and vendor again), or needs a new CMake option or
  library (`build.rs`). A new third-party directory brings its licence: add it to `Cargo.toml`'s
  `license` and to [README.md](README.md#origin-and-licence).
- **A test, the documentation's example or a documentation link breaks**: a function they use was
  removed or changed. Update `tests/` or `src/lib.rs` to the new C API.
- **A lint fails on the bindings**: `src/lib.rs` expects lints on the `bindings` module
  (`non_snake_case`, `unsafe_code`). An expectation the new bindings no longer need is
  unfulfilled, and a lint they now trigger isn't expected: remove or add the `#[expect]`, with its
  reason.
- **The vendored tree differs from the release** (`scripts/vendor-binaryen.sh --check`): someone
  edited `binaryen/`, or the release's tag moved upstream. Vendor the release again; if the tag
  moved, find out why before going on.
- **The bindings differ from what the script generates**: someone edited `src/bindings.rs`, or a
  change of the script wasn't followed by a regeneration. Regenerate.

### Finishing an update by hand

1. Fetch the branch `update-binaryen`, which holds the workflow's commit
   `BUILD: Binaryen version_<N>` (the vendored release, the bindings, the version `<N>.0.0`).
2. Commit the fix on it and push it. From then on, the workflow leaves the branch alone and its
   runs fail, which shows the update is in a person's hands.
3. Open a pull request from the branch, so CI runs on it, until it passes.
4. Squash the branch into one commit `BUILD: Binaryen version_<N>`, so that the commit reaching
   `main` is the one that sets the version, fast-forward `main` to it and push, then tag it
   `v<N>.0.0` and push the tag ([Versions and releases](#versions-and-releases)), and delete the
   branch.

## Dependencies

The crate has one dependency, the `cmake` build dependency. A new one is a decision for the
maintainers, with its reason in the pull request.
