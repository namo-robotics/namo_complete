# Sun feedback: migration record

This document is the historical record of the Sun compiler and standard-library
gaps found while building `namo_complete`. The original issue drafts were
written against `sun 0.dev (b70da5b9a992)` on 2026-08-22. The project now
targets the rolling dev release built from `fda0b191180f`, verified on 2026-09-25.
Use `./upgrade-sun.sh` to install a complete compiler and matching bundles into
the ignored `.sun/` directory; `build.sh` prefers that toolchain.

## Changes adopted from the latest release

- **Terminal size queries.** `std.terminal.get_size` replaces the platform-specific
  size-read ioctl and constants. Setting the relay PTY size still needs FFI.
- **Explicit exception borrows.** Catch bindings use `const ref IError`.
  JSON construction errors now reach the existing request failure handler.
- **Checked string operations.** Byte reads, substring copies, edits, and pops
  now account for the standard library's bounds errors. The nonthrowing parser
  helpers return NUL or an empty string for an invalid range, and an extra
  backspace on an empty output line is harmless.
- **Checked container access.** Vectors and buffers use throwing `get` and `set`
  methods, with errors propagated to request boundaries or handled locally for
  optional output recording. There are no unchecked container operations.
  Container indexing failed LLVM verification for a String-valued expression
  in this release; checked methods compile successfully and avoid that issue.

## Fixes already adopted in the previous migration

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

The current artifacts do not yet expose public PTY allocation, terminal
window-size setters, or a read-write nonblocking file-open mode. The relay therefore keeps a
small FFI layer in `src/platform_linux.sun` and `src/platform_macos.sun`. All
shared recorder, tracker, polling, and shell behavior remains platform-neutral.

The current I/O APIs also still borrow runtime paths and contents as `ref
String`, and allocator-using I/O, JSON, environment, process, and polling entry
points still take `ref HeapAllocator`. Functions that touch those APIs retain
mutable borrows; no defensive path copies are introduced merely to claim
`const`. Directory-entry names still require mutable borrows. Sorting copies
one candidate name before borrowing another entry, as the latest borrow checker
rejects the overlapping mutable borrows accepted by the earlier compiler.

Finally, `/usr/share/doc/sun/changelog.gz` still contains only `Release 0.dev`.
The rolling GitHub release identifies its source commit and artifacts, but does
not enumerate API additions, renames, or removals. `namo_complete --version`
therefore continues to stamp both its own commit and the exact Sun build.

## Current dependency boundary

Production HTTPS is entirely in Sun's `tls.moon`; curl is only needed by the
bootstrap installer and CI to download release artifacts. Release binaries do
not write the API key to disk or expose it in a child process. The two platform
files above are the only application sources that declare C functions or use
`unsafe`; those expressions are confined to the platform FFI calls.


## Terminal freeze investigation

The shell opened its request FIFO read-write, which avoids a blocking open but
still permits blocking writes. A busy or stopped daemon can fill this pipe;
zsh's redraw hook, Bash's prompt/key hooks, and even the exit hook then stop in
`printf`. The full-pipe regression reproduces this indefinitely on the original
integration. Startup now marks the shell's shared descriptor nonblocking through
a short-lived helper. Records are limited to the portable atomic pipe-write
size so a full pipe drops a complete request without emitting a partial record.
Oversized requests also fail immediately. Daemon reply writes are nonblocking
so a shell that has stopped reading cannot wedge the daemon.

A separate unbounded read in bracketed-paste parsing could swallow subsequent
keys indefinitely when the paste terminator was missing. Both integrations now
bound each continuation read and cancel immediately on Ctrl-C. Ordinary ask-mode
typing still has no idle timeout. `test-terminal.py` covers these cases with
input kept open, so EOF cannot conceal a blocking read.


## macOS archive linker compatibility

The macOS `fda0b191180f` TLS bundle contains an OpenSSL crypto archive whose
members use two-byte alignment. The Apple linker on the `macos-15` runner
(default Xcode 16.4) assumes four-byte alignment and fails with
`archive member invalid control bits`. Walking the downloaded archive with
that older alignment rule reproduces the failure after
`libcommon-lib-der_digests_gen.o`; its headers and symbol offsets are otherwise
valid. Apple's newer archive reader uses two-byte alignment.

CI and release builds therefore use `macos-26`, matching the newer toolchain
used to publish Sun's macOS artifact. `MACOSX_DEPLOYMENT_TARGET=15.0` keeps the
binary's deployment floor at the previous runner's OS version. Both workflows
print their Xcode and linker versions for future diagnosis. Local macOS builds
with this bundle also need a newer Apple linker; installing LLVM for the Sun
compiler does not replace the Apple linker selected by `cc`.
