# Sun feedback: migration record

This document is the historical record of the Sun compiler and standard-library
gaps found while building `namo_complete`. The original issue drafts were
written against `sun 0.dev (b70da5b9a992)` on 2026-08-22. The project now
targets the rolling dev release built from `70888282d872` on 2026-09-02.

## What the current release resolved

- **Apple Silicon macOS builds.** Sun now emits and links Mach-O arm64 programs,
  publishes an `arm64-apple-darwin` compiler tarball, and ships matching
  `stdlib.moon` and `tls.moon` bundles. `namo_complete` consequently publishes
  `macos-arm64` alongside `linux-x86_64`.
- **Verified TLS.** The `tls` bundle provides `TlsStream`, certificate and
  hostname verification, SNI, and HTTP response framing. `namo_complete` now
  talks to Anthropic without curl, a request-body file, or a transport child
  process.
- **Modern module and language surface.** The project uses the `std` namespace,
  `source_files`/`libraries` manifests, target-specific manifest entries,
  `method`, `throws IError`, captured `Env`, the renamed JSON constructors,
  `read_unix_time`, and current container APIs.
- **Earlier compiler and stdlib fixes.** Diagnostics, method arity checking,
  general `spawn` lambdas, owned error messages, field borrows, nonempty string
  splitting, logical-operator guidance, JSON string copying, and public
  `static_ptr` accessors remain adopted throughout the codebase.

## What remains outside the shipped stdlib

The current artifacts do not yet expose PTY allocation, terminal window-size
ioctls, or a read-write nonblocking file-open mode. The relay therefore keeps a
small FFI layer in `src/platform_linux.sun` and `src/platform_macos.sun`. All
shared recorder, tracker, polling, and shell behavior remains platform-neutral.

The current I/O APIs also still borrow runtime paths and contents as `ref
String`, and allocator-using I/O, JSON, environment, process, and polling entry
points still take `ref HeapAllocator`. Functions that touch those APIs retain
mutable borrows; no defensive path copies are introduced merely to claim
`const`.

Finally, `/usr/share/doc/sun/changelog.gz` still contains only `Release 0.dev`.
The rolling GitHub release identifies its source commit and artifacts, but does
not enumerate API additions, renames, or removals. `namo_complete --version`
therefore continues to stamp both its own commit and the exact Sun build.

## Current dependency boundary

Production HTTPS is entirely in Sun's `tls.moon`; curl is only needed by the
bootstrap installer and CI to download release artifacts. Release binaries do
not write the API key to disk or expose it in a child process. The two platform
files above are the only application sources that declare C functions or use
`unsafe`.
