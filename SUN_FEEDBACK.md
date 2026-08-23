# Sun feedback, as issue drafts

Each section below is a self-contained issue body, ready to file against the
[Sun](https://namo-robotics.github.io/sun/) repository — repro, observed
behaviour, expectation, impact. They come out of writing
[`namo_complete`](https://github.com/namo-robotics/namo_complete), an
LLM-powered bash completion tool: ~2800 lines of Sun with a network client, a
file cache, a long-lived daemon and a pty in front of the shell.

Every repro is standalone, and every one was re-run against the build named in
its Environment line before this was written. Items fixed in earlier builds have
been dropped along with the workarounds they forced. `b70da5b9a992` (2026-08-22)
is the newest published build, and it closed ten of the fourteen items the
previous edition of this file carried:

- **Compiler crash on `var t = void_call();`** — now
  `Cannot infer a type for variable 't': the value assigned to it produces no result`,
  with file and line.
- **Method calls skipped arity checking** — `s.trim(alloc)` now gets
  `No matching overload of 'trim' for argument types (HeapAllocator)`, the same
  message free functions always had.
- **`spawn` took only an inline `i32` lambda** — `spawn(lambda() void { })`,
  with or without binding the handle, and `spawn(f)` for a lambda held in a
  variable all compile and run.
- **`Error` could not carry a computed message** — `Error(code, const ref
  String)` exists, and `IError.message()` returns an owned `String`.
- **A `ref` local could not be bound to a class field** —
  `var pick: ref String = h.a;` and `var pick: ref String = h.flag ? h.a : h.b;`
  both work. This project's one-shot path uses the ternary form now.
- **`String.split` kept empty pieces** — `split_nonempty(alloc, sep)` and
  `split_whitespace(alloc)` were added. They replaced a hand-written
  whitespace collapser and two character-by-character word scanners here.
- **`partial` was a reserved word with a misleading diagnostic** — now
  `'partial' is a reserved word and cannot be used as an identifier`.
- **`&&` / `||` did not suggest `and` / `or`** — now
  `unexpected '&&' - Sun spells logical and as 'and'`.
- **`Json(String)` took ownership undocumented** — the ownership rule is in the
  module header and `json_string(alloc, const ref String)` stores a copy.
- **`_static_ptr_data` / `_static_ptr_len` were the only way to read a
  `static_ptr`** — `static_ptr` has `.raw()` and `.length()`, and the stdlib
  itself no longer calls the intrinsics.

Between them they let this project delete the `c_str()` bridge in front of
every `sun.io` call, two more `extern "C"` declarations (`read` and `strlen`,
now `File.read_into` and `from_c_str`) and three `unsafe` blocks. The same
build also added `const ref` parameters and `const function` methods to the
language, which this project adopted throughout; the one place that could not
is issue #4.

Ordered by severity: things that block a platform or shape the architecture,
then the new `const` gap, then process.

---

## 1. No macOS target: `extern "C"` is ELF-only, and there is no link driver for Darwin

**Environment:** `sun 0.dev (b70da5b9a992)`, building on x86_64 Linux.

**Repro** — any program at all, now that the stdlib itself uses the FFI:

```
$ sun -c --target aarch64-apple-darwin -o out src/main.sun
Error: no C ABI rules for target 'aarch64-apple-darwin';
       extern "C" supports x86_64 and aarch64 (ELF) only
```

`x86_64-apple-darwin` gets past the ABI check and now fails with a clear
message instead of a silent link error, which is an improvement:

```
Compilation failed: no link driver for target 'x86_64-apple-darwin':
  install x86_64-apple-darwin-gcc or clang (or set SUN_CC),
  or stop at --emit-obj and link on the target machine
```

But the stdlib module it would link was compiled for `x86_64-pc-linux-gnu` (the
compiler warns about the mismatched triples and data layouts on the way), so
there is nothing a Darwin linker could usefully take.

**Requested:** Mach-O argument classification and an `aarch64-apple-darwin`
ABI, and a stdlib module built for the target.

**Impact:** `stdlib/sys.sun` routes every libc call the standard library makes
through `extern "C"`, so the ELF restriction is not something an application
can avoid by avoiding the FFI: any program that opens a file is in the same
position as this one. This is the single highest-impact addition for anyone
shipping a Sun program to end users.

Adjacent: upstream publishes only `sun_0.dev_amd64.deb`, so there is no macOS
toolchain to build with either.

---

## 2. No TLS, so any HTTPS client has to shell out

**Environment:** `sun 0.dev (b70da5b9a992)`, x86_64 Linux.

`networking.sun` provides raw IPv4 TCP and `http.sun` provides a plaintext HTTP
*server*. There is no HTTPS client and no TLS socket anywhere in the stdlib
(`grep -il 'tls\|ssl' stdlib/*.sun` returns nothing).

**Requested:** an HTTPS client, or failing that, TLS sockets to build one on.

**Impact:** for a program whose entire job is calling an HTTPS API, the whole
transport is a subprocess wrapper around the `curl` binary
([`src/client.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/client.sun)).

`sun.process.Command` makes that wrapper as good as a wrapper can be: there is
no shell, `Command` execs curl directly, the request body is one argv entry,
the API key goes down curl's stdin as a `-K -` config so it appears neither on
disk nor in `ps`, and `Child.collect` returns the response having polled both
pipes. It is still a runtime dependency on an external binary, in a language
whose static-linking story is otherwise its best feature. FFI to libcurl was
considered and rejected: Sun links statically by default, libcurl commonly ships
as a `.so` only (needing `--dynamic` plus a `-dev` package), and **Sun's FFI
rejects function pointers**, which rules out libcurl's write-callback API.

---

## 3. No pseudo-terminal support, and `sun.io` cannot express the flags around it

**Environment:** `sun 0.dev (b70da5b9a992)`, x86_64 Linux.

There is no way to allocate a pty from Sun. `sun.io` opens files, `sun.process`
runs children, `Poller` waits on descriptors — but nothing creates the terminal
a child would be given, and nothing sets or reads a window size.

**Requested:** pty allocation (`posix_openpt` / `grantpt` / `unlockpt` /
`ptsname`, or one call that returns a master/slave pair), and a way to get and
set a terminal's window size.

Two smaller gaps sit next to it, both hit in the same file:

- `File.open` takes a `FileMode` of `Read`, `Write` or `Append`, so there is no
  way to ask for read-write, or for `O_NONBLOCK`. Opening a FIFO read-write is
  the standard way to hold a pipe open without blocking on a reader and without
  risking `SIGPIPE`; expressing it needs a raw `open`, and that `open` is the
  only reason `String.c_str()` is still called anywhere in this project.
- `ioctl` is not exposed at all, which is what the window size needs.

**Impact:** this is the one thing keeping FFI in a project that otherwise has
none. `b70da5b9a992` took two more declarations back into the stdlib — `read`
became `File.read_into` on an adopted descriptor, `strlen` went with
`from_c_str` — so
[`src/cmd_output_relay.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/cmd_output_relay.sun)
is down to six `extern "C"` declarations and seven `unsafe` blocks, all of
them for the pty, the window size and the FIFO flags. Nothing else in the
project calls C.

A pty is not an exotic requirement: it is what anything wanting to sit between a
shell and its terminal needs — a recorder, a multiplexer, a test harness driving
an interactive program. And because of issue #1, that file is also the reason
the whole project cannot target macOS.

---

## 4. `const ref` stops at the stdlib's allocator and path parameters

**Environment:** `sun 0.dev (b70da5b9a992)`, x86_64 Linux.

`const ref` and `const function` are a welcome addition, and the diagnostics
are exactly right (`Cannot call non-const method 'trim' on const reference
's'; declare it 'const function' if it does not change the object`). The
stdlib adopted them almost everywhere — but not in the two places a read-only
function most needs them: every entry point that takes an allocator, and every
`sun.io` path.

**Repro A — a path read out of a const object cannot be opened**

```sun
using sun;
using sun.io;

public class Cfg {
  public var path: String;
  public function init(alloc: ref HeapAllocator) { this.path = String(alloc, "/etc/hostname"); }
}

function size_of(alloc: ref HeapAllocator, cfg: const ref Cfg) i64, IError {
  var text = read_to_string(alloc, cfg.path);
  return text.length();
}
```
```
Error: c6.sun:8:14: Cannot pass as 'ref' argument 2 of 'read_to_string'
       const reference 'cfg'
```

`File.open`, `read_to_string`, `write_string` (both the path and the contents),
`remove_file`, `make_dir`, `read_dir`, `exists` and `rename_file` all borrow
`ref String`, though none of them writes to it. `String.c_str()` is not a
`const function` either, so the raw-`open` escape hatch is closed too.

**Repro B — a `const ref HeapAllocator` cannot reach half the stdlib**

```sun
function size_of(alloc: const ref HeapAllocator, path: ref String) i64, IError {
  var text = read_to_string(alloc, path);
  return text.length();
}
```
```
Error: c7.sun:4:14: No matching overload of 'read_to_string' for argument types
       (const ref HeapAllocator, ref String). ...
```

`String`, `Vec`, `ContiguousBuffer`, `clone`, `split`, `join` and `from_c_str`
take `const ref HeapAllocator`; `read_to_string`, `File.read_all`, `read_dir`,
`Poller`, `Command`, `json_parse`, `json_string`, `json_object`, `sun.env.get`
and `args` take `ref HeapAllocator`. `HeapAllocator` is stateless and its
`copy()` is already `const`, so nothing in the second group needs the
mutable borrow.

**Expected:** `const ref String` for every path and content parameter in
`sun.io`, `const function c_str()`, and `const ref HeapAllocator` in the
entry points listed.

**Impact:** the sweep that marked every read-only parameter in this project
`const` had to leave two holes. `alloc` is `ref` in every signature, because a
`const ref` allocator cannot be handed to anything that reads a file or parses
JSON. And `cfg` — the configuration object, read-only by design — is `const ref`
in the functions that only look at it and `ref` in the eight that open one of
its files, with a comment in
[`src/fs.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/fs.sun)
explaining the split. The alternative was to `clone()` a path just to open it,
which is the kind of copy `const ref` exists to remove.

---

## 5. Stdlib changes ship with no deprecation window or changelog

**Environment:** `sun 0.dev (b70da5b9a992)`, x86_64 Linux.

`b70da5b9a992` is another large and very welcome release — and upgrading to it
broke this project's build in two new ways, neither announced. This is the
second consecutive build to do so. `/usr/share/doc/sun/changelog.gz` still
reads, in full, `* Release 0.dev`.

1. **`sun.io` and `sun.env` dropped their `raw_ptr<u8>` overloads.** The
   previous build's path parameters were `raw_ptr<u8>`, satisfied by
   `String.c_str()`; this build replaced them with a `static_ptr<u8>` /
   `ref String` pair and removed the `raw_ptr` form. The new shape is the right
   one — it is what this file asked for — but every existing call site is a
   hard error with no compatible overload:

   ```
   Error: src/fs.sun:20:7: No matching overload of 'make_dir' for argument
          types (raw_ptr(u8), i32). Available overloads:
     - make_dir(static_ptr(u8), i32)
     - make_dir(ref String, i32)
   ```

   The message is excellent and the fix was mechanical. It was still a
   surprise, on a project whose CI pulls the rolling `dev` package and was red
   until it was found.

2. **`IError.message()` changed its return type.** `static_ptr<u8>` became
   `String`, so every class that implements `IError` stops compiling:

   ```
   Error: e.sun:2:1: Class 'MyError' method 'message' has return type
          'static_ptr(u8)' but interface 'IError' requires return type 'String'
   ```

   Again the right change (it is what made computed error messages possible),
   again nothing said so.

From the previous two upgrades, still unaddressed: `sun.print` gained `eprint`
and collided with an application function of the same name under `using sun;`;
`File.open`'s mode, `seek`'s whence and `File.write`'s return type all changed
shape together; `Vec.borrow_unchecked` became `get_unchecked`. Every one of
these was an improvement, and every one was found by building and reading the
error.

**Requested:** release notes listing stdlib additions, renames and removals —
even two lines per build — and, for renames, one release where the old name
still works and warns.

**Impact:** upgrading the compiler is an unbounded task. There is no way to
know what will break before trying it, and no way to tell a rename from a
removal without reading the stdlib sources. That discourages tracking `dev`,
which is where the fixes are — and this build shows how much is there.

---

## Not an issue: what already works well

Worth recording alongside the list above.

The diagnostics in `b70da5b9a992` are the best thing about it. Every compiler
crash and every verifier failure in the previous edition of this file is now a
one-line message with a file, a line and a caret, and the messages say what to
do: `declare it 'const function' if it does not change the object`, `Sun spells
logical and as 'and'`, `'partial' is a reserved word`. The arity check on method
calls lists the available overloads. When this build broke the project (issue
#5), the first error named the exact overloads that did exist, and the port
from the old `c_str()` bridge to the new `ref String` forms took minutes — and
passed all 138 tests on the first run.

`const ref` / `const function` is a good design: a `ref` argument passes to a
`const ref` parameter without ceremony, a `const ref` argument into a `ref`
parameter is refused with the method named, and a write to `this` inside a
`const function` is caught at the assignment. Marking this project's read-only
parameters took one pass and the compiler found the two it could not mark
(issue #4).

`split_whitespace` + `join` replaced a 17-line whitespace collapser with two
lines; `split_nonempty` took a filter out of every line-splitting call site;
`json_string(alloc, const ref String)` removed the defensive clones around
every request body; `Error(code, const ref String)` means an error can finally
name the path that failed. `from_c_str` and `File.adopt` + `read_into` took
two more C declarations out of the one file that still has any.

From before: `Command` / `Child` / `Output`, `Poller`, `read_dir`, `sun.env` and
`sun.time` replaced every line of FFI this project had at the time, and
`Child.collect` polling both pipes rather than draining one and then the other
was simply right. `spawn` gives an OS thread from a language keyword, with
`join()` returning the lambda's value and a blocking subprocess inside the
worker leaving the main loop's timing untouched — and now accepts the two
shapes that used to crash. The borrow checker caught a real use-after-move in
this project's JSON code on the first compile. `manifest { suns: [...] }`
multi-file builds and cross-module `public` visibility worked first try. The
allocator held flat at 1052 KB RSS across 100k iterations of
`String`/`Vec`/`ContiguousBuffer` churn, which is what made a long-lived daemon
a reasonable thing to write at all. A statically linked 1.7 MB binary with no
runtime dependencies is exactly the right deployment story for a shell
integration.
