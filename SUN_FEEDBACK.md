# Remaining Sun feedback

Checked against the rolling dev release `cc7686189ee2` on 2026-10-14.
Install the compiler and matching bundles with `./upgrade-sun.sh`.
Resolved migration items and fixed application bugs have been removed.

## Terminal and file APIs

The shipped standard library still lacks public PTY allocation, a terminal
window-size setter, and a read-write nonblocking file-open mode. These operations
remain in `src/platform_linux.sun` and `src/platform_macos.sun`.

## Borrowing limitations

Runtime-path I/O, JSON, environment, process, and polling APIs still require
mutable allocator or string borrows in several signatures. Directory-entry
`name()` also requires a mutable borrow even when only reading the name.

Checked container access returns a mutable reference. In this release, a
chained expression such as `(try entries.get(i)).name().clone(alloc)` can keep
the container borrowed while the owned copy remains in scope, preventing a
second checked access. `clone_item` and `clone_entry_name` isolate these borrows
inside functions returning owned strings. JSON parsing similarly orders reads
and holds one content borrow to avoid overlapping mutable accesses.

## Release change documentation

The packaged `changelog.gz` still says only `Release 0.dev`. The rolling GitHub
release identifies its source commit and artifacts but does not enumerate API
additions, renames, or removals. This upgrade required replacing `throws` and
block-form `try`/`catch` with result enums throughout the application.

## macOS archive compatibility

The previously validated `fda0b191180f` TLS bundle used two-byte-aligned OpenSSL
archive members that the default Xcode 16.4 linker on `macos-15` rejected with
`archive member invalid control bits`. CI and release builds use `macos-26`,
with `MACOSX_DEPLOYMENT_TARGET=15.0`, to supply the newer Apple archive reader.
Installing LLVM alone does not replace the Apple linker selected by `cc`.
A native macOS link with the latest bundle has not been verified locally, so
this compatibility constraint remains open.
