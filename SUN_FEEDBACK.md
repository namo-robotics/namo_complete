# Sun feedback, as issue drafts

Each section below is a self-contained issue body, ready to file against the
[Sun](https://namo-robotics.github.io/sun/) repository — repro, observed
behaviour, expectation, impact. They come out of writing
[`namo_complete`](https://github.com/namo-robotics/namo_complete), an
LLM-powered bash completion tool: ~1650 lines of Sun with a network client, a
file cache and a long-lived daemon.

Every repro is standalone, and every one was re-run against the build named in
its Environment line before this was written. Items fixed in earlier builds have
been dropped along with the workarounds they forced.

The `46190fcbc286` stdlib closed three of them outright, and they are gone from
the list below: `String.c_str()` ended the hand-rolled C-string bridge, the
`sun.io` path parameters moved from `static_ptr<u8>` to `raw_ptr<u8>`, and
`sun.process` / `sun.env` / `sun.time` plus `read_dir` and `Poller` covered
every process, directory and environment call this program had been making
through the FFI. Between them they deleted two source files and every
`extern "C"` declaration and every `unsafe` block in the project — it now
compiles with none of either. A fourth item, "no narrowing conversion between
integer types", was withdrawn rather than fixed: `_convert<i32>` truncates
correctly and always did, on this build and the one before it. The issue was
wrong.

Ordered by severity: compiler crashes, then things that shaped the
architecture, then papercuts.

---

## 1. Compiler crashes (SIGTRAP, no diagnostic) when a `void` result is bound to an inferred `var`

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux, `sun -c` (static AOT).

Assigning the result of a `void` function to a `var` without a type annotation
crashes the compiler. There is no diagnostic at all — no error, no partial
output, just a core dump.

**Repro**

```sun
using sun;

function nothing() void { }

function main() i32 {
  var t = nothing();
  return 0;
}

manifest { moons: ["stdlib.moon"] }
```

```
$ sun -c -o crash crash.sun
Trace/breakpoint trap (core dumped)
$ echo $?
133
```

**Expected:** the same diagnostic the annotated form already produces. With an
explicit type it is handled cleanly, which suggests the check exists and is
simply not reached on the inference path:

```sun
var t: i64 = nothing();
```
```
Error: crash.sun:4:3: Cannot assign value of type 'void' to variable 't' of type 'i64'
```

**Impact:** easy to hit by accident, because several stdlib mutators return
`void` and edit in place — `String.trim()`, `trim_start()`, `trim_end()`,
`to_lower()`, `to_upper()`, `replace()`. Writing `var t = s.trim();`, which is
what anyone coming from a language with immutable strings will try first, takes
out the build with no clue as to where. A one-line source change produces a
crash with no file, no line and no message.

---

## 2. Method calls skip arity checking and fail in the LLVM verifier

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux, `sun -c` (static AOT).

Passing the wrong number of arguments to a **method** is not caught by overload
resolution. It reaches code generation and fails in the LLVM verifier, with a
message that names a mangled symbol and no source location. The same mistake on
a **free function** produces a clean, helpful diagnostic — so the check exists,
but is not applied to method calls.

**Repro**

```sun
using sun;

function main() i32 {
  var alloc = make_heap_allocator();
  var s = String(alloc, "x");
  s.trim(alloc);          // String.trim() takes no arguments
  return 0;
}

manifest { moons: ["stdlib.moon"] }
```

**Actual**

```
Incorrect number of arguments passed to called function!
  call void @"$f25b09f5$_sun_String_trim"(ptr %method.closure1, %"$f25b09f5$_sun_HeapAllocator_struct" %move.val)
Error: Function verification failed: main
```

**Expected:** what the free-function path already gives. The identical mistake
on a free function is caught properly:

```sun
function nothing() void { }
function main() i32 {
  nothing(42);
  return 0;
}
```
```
Error: t.sun:4:3: No matching overload of 'nothing' for argument types (i32).
Available overloads:
  - nothing()
```

Too *few* arguments is caught the same way, so the gap is specific to method
calls, not to arity checking in general.

**Impact:** the error names no file and no line, so on a multi-file build
(`manifest { suns: [...] }`) there is nothing to bisect from but the mangled
name. This is exactly the mistake an API change provokes — a method that used to
take an allocator and no longer does, say — which is when a clear message
matters most. Porting this project to the `46190fcbc286` stdlib, where
`File.open` changed shape, was that situation.

---

## 3. `Error` cannot carry a computed message

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

`sun.io` and friends now take paths as `raw_ptr<u8>`, which a runtime `String`
satisfies through `c_str()`. `Error` did not move with them: its message is
still `static_ptr<u8>` (errors.sun:27), satisfied only by a compile-time
literal.

**Repro**

```sun
function boom(path: ref String) void, IError {
  throw Error(-1, path);
}
```
```
Error: e.sun:4:63: No matching constructor for '$f25b09f5$_sun_Error'
       with arguments (i32, ref(String))
```

**Expected:** an `Error` constructor accepting an owned or borrowed `String`.

**Impact:** an `IError` cannot name the path that failed, the URL that timed
out, or the value that would not parse. Every failure has to either drop its
detail or carry it out-of-band in a field the catcher knows to read — this
project does the former, so a cache write that fails on a bad path throws an
error saying only "failed to write file". Now that `c_str()` and the
`raw_ptr<u8>` path parameters have made every *other* stdlib entry point usable
with computed values, this is the one left.

---

## 4. No macOS target: `extern "C"` is ELF-only, which blocks distribution entirely

**Environment:** `sun 0.dev (46190fcbc286)`, building on x86_64 Linux.

**Repro** — any program at all, now that the stdlib itself uses the FFI:

```
$ sun -c --target aarch64-apple-darwin -o out src/main.sun
Error: no C ABI rules for target 'aarch64-apple-darwin';
       extern "C" supports x86_64 and aarch64 (ELF) only
```

`x86_64-apple-darwin` gets past the ABI check and then fails at link.

**Requested:** Mach-O argument classification and an `aarch64-apple-darwin` ABI.

**Impact:** this got *broader* with the new stdlib, not narrower. `stdlib/sys.sun`
routes every libc call the standard library makes through `extern "C"`, so the
ELF restriction is no longer something an application can avoid by avoiding the
FFI: `namo_complete` now contains no `extern "C"` and no `unsafe` block
anywhere, and still cannot be built for macOS, because `sun.io` and
`sun.process` can't be. Any program that opens a file is in the same position.
This is the single highest-impact addition for anyone shipping a Sun program to
end users.

Adjacent: upstream publishes only `sun_0.dev_amd64.deb`, so there is no macOS
toolchain to build with either.

---

## 5. No TLS, so any HTTPS client has to shell out

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

`networking.sun` provides raw IPv4 TCP and `http.sun` provides a plaintext HTTP
*server*. There is no HTTPS client and no TLS socket anywhere in the stdlib
(`grep -l 'tls\|TLS\|SSL' stdlib/*.sun` returns nothing).

**Requested:** an HTTPS client, or failing that, TLS sockets to build one on.

**Impact:** for a program whose entire job is calling an HTTPS API, the whole
transport is a subprocess wrapper around the `curl` binary
([`src/client.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/client.sun)).

`sun.process.Command` made that wrapper a great deal better than it was — the
old one wrote a mode-0600 curl config to disk, `chdir`'d so that the command
string could be a compile-time constant, called `system()`, and read the
response back out of a file, all to keep user bytes away from `/bin/sh`. There
is no shell now: `Command` execs curl directly, the request body is one argv
entry, the API key goes down curl's stdin as a `-K -` config so it appears
neither on disk nor in `ps`, and `Child.collect` returns the response having
polled both pipes. That is a real improvement in a security-relevant path and it
came free with the stdlib.

It is still a runtime dependency on an external binary, in a language whose
static-linking story is otherwise its best feature. FFI to libcurl was
considered and rejected: Sun links statically by default, libcurl commonly ships
as a `.so` only (needing `--dynamic` plus a `-dev` package), and **Sun's FFI
rejects function pointers**, which rules out libcurl's write-callback API.

---

## 6. A `ref` local cannot be bound to a class field

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

Borrowing a field into a local is rejected, even though passing the same field
as a `ref` parameter borrows it fine.

**Repro**

```sun
using sun;

public class Holder {
  public var a: String;
  public function init(alloc: ref HeapAllocator) { this.a = String(alloc, "one"); }
}

function main() i32 {
  var alloc = make_heap_allocator();
  var h = Holder(alloc);
  var pick: ref String = h.a;
  println(pick);
  return 0;
}
```
```
Error: r.sun:11:3: Cannot assign value of type 'String' to variable 'pick'
       of type 'ref(String)'
```

**Expected:** `var pick: ref String = h.a;` binds a borrow, the same way
`f(h.a)` does for a `ref String` parameter.

Passing the same field as a `ref` parameter does borrow it, and works:

```sun
function show(s: ref String) void { println(s); }
show(h.a);        // fine -- h.a is still usable afterwards
```

The conditional form fails the same way, even though Sun has a ternary and it
compiles for values:

```sun
var pick: ref String = h.flag ? h.a : h.b;
```
```
Error: r.sun:16:3: Cannot assign value of type 'String' to variable 'pick'
       of type 'ref(String)'
```

**Impact:** any borrow that depends on a condition has to be written as
duplicated branches, because the choice cannot be made once and reused. From
this project, where the two arms differ only in which field they read:

```sun
var prefix = String(alloc, "");
if (cfg.is_ask()) {
  prefix = cfg.query.clone(alloc);
} else {
  prefix = cfg.line.clone(alloc);
}
```

The clone is there only because the borrow cannot be named — with a `ref` local
this would be one line and no copy.

---

## 7. `String.split` keeps empty pieces, and there is no whitespace-collapsing helper

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

`String.split(alloc, sep)` emits an entry for every separator including runs and
trailing separators, so splitting text into lines or words means writing a
filter at every call site.

**Repro**

```sun
var s = String(alloc, "a,,b,");
var p = s.split(alloc, 44);   // ','
```
```
pieces: 4
  [a]
  []
  [b]
  []
```

**Requested:** either a `split` variant that drops empty pieces, or a
`split_whitespace` that treats runs as one separator.

**Impact:** minor but universal — `split_lines` in
[`src/util.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/util.sun)
is a wrapper that exists only to filter the empties back out. `normalize_ws`
(collapse whitespace runs to single spaces) is the one helper in that file with
no stdlib equivalent at all.

---

## 8. `partial` is a reserved word, with a diagnostic that does not say so

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

**Repro**

```sun
var partial = 1;
```
```
Parse Error: p.sun:3:7: expected identifier after 'var'
```

**Expected:** a message naming the cause, e.g. `'partial' is a reserved word`.

**Impact:** the message points at the wrong thing entirely — it reads as a
parser bug, not a name collision, so the natural response is to doubt the
surrounding syntax. `partial` is not listed as a keyword in the docs, so finding
it took a bisect. A reserved-word list in the docs would also do.

---

## 9. `&&` / `||` produce a parse error that does not suggest `and` / `or`

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

**Repro**

```sun
if (true && false) { return 1; }
```
```
Parse Error: a.sun:3:13: unknown token when expecting an expression
```

**Expected:** `unexpected '&&' — Sun spells logical and as 'and'`.

**Impact:** small, but it is the first thing nearly every newcomer will type.
Using `and`/`or` is a reasonable design choice; the error just does not connect
it to what was written.

---

## 10. `Json(...)` takes ownership of its `String`, which is not documented

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

`Json(s: String)` consumes the string, so any value still needed after being
placed into a document has to be cloned first:

```sun
req.set(String(alloc, "model"), Json(cfg.model.clone(alloc)));
//                                            ^^^^^^^^^^^^^ or cfg.model is emptied
```

**Requested:** a note in the JSON documentation, or a `ref String` overload that
copies.

**Impact:** the borrow checker does catch the mistake, so this costs a build
cycle rather than a bug. Worth documenting because building a request body is
the common case, and it is where values are most likely to be reused.

---

## 11. Stdlib changes ship with no deprecation window or changelog

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

The `46190fcbc286` stdlib is a large and very welcome release — and upgrading to
it broke this project's build in three unrelated ways, none of them announced.
`/usr/share/doc/sun/changelog.gz` reads, in full, `* Release 0.dev`.

1. **A new stdlib free function collided with an existing application one.**
   `sun.print` gained `eprint`. This project had its own `eprint`, and every
   file says `using sun;`, so the build stopped at:

   ```
   Error: Ambiguous reference to 'eprint'. Could be: namo or sun
   ```

   The error is clear, but the hazard is not bounded: adding any public free
   function to a `using`-imported module can break any program that already has
   that name. `sun.sys` shows the shape of the fix — every libc extern in it is
   prefixed `c_` and kept private specifically so that `getenv`, `fork` and
   `poll` stay free in user namespace. The same care in the public modules, or a
   release note, would have covered this.

2. **`sun.io` changed shape without a compatible overload.** `File.open`'s mode
   went from `i32` constants (`MODE_READ`) to a `FileMode` enum, `seek`'s
   whence went from `SEEK_*` to a `Whence` enum, `File.write` changed its return
   type from `i32` to `i64`, and the "not open" sentinel for a `File`'s
   descriptor moved from `-1` to `0`. Each of these is an improvement. Together
   they are a silent source break for every existing caller.

3. **A rename with no deprecation.** `Vec.borrow_unchecked` became
   `Vec.get_unchecked` in an earlier build, again with no note; the only way to
   find out what changed was to diff the stdlib sources.

**Requested:** release notes listing stdlib additions and renames, and — for
renames — one release where the old name still works and warns.

**Impact:** upgrading the compiler is an unbounded task. There is no way to know
what will break before trying it, and no way to tell a rename from a removal
without reading the sources. That discourages tracking `dev`, which is where the
fixes are. This upgrade was worth every minute it cost, and a two-line note
would have made it cost almost nothing.

---

## 12. `_static_ptr_data` / `_static_ptr_len` are documented as discouraged, but are the only option

**Environment:** `sun 0.dev (46190fcbc286)`, x86_64 Linux.

The docs describe `_static_ptr_data<T>` and `_static_ptr_len<T>` as intrinsics
to avoid, yet they are the only way to do anything with a `static_ptr` value —
and the stdlib's public API still hands `static_ptr<u8>` parameters to callers
(`Error`, `String.equals_literal`, `starts_with`, `File.write`).

**Requested:** either a supported accessor for `static_ptr`, or documentation
acknowledging that these intrinsics are the intended tool for it.

**Impact:** much reduced by this stdlib. Now that paths are `raw_ptr<u8>` and a
literal narrows to one automatically, this project no longer calls either
intrinsic anywhere. What is left is a documentation contradiction rather than a
daily inconvenience — but it still bites anyone who has to read the bytes of a
`static_ptr` they were handed, which issue #3 shows is still reachable.

---

## Not an issue: what already works well

Worth recording alongside the list above.

The `46190fcbc286` stdlib is the best thing to happen to this project. `Command`
/ `Child` / `Output`, `Poller`, `read_dir`, `sun.env` and `sun.time` replaced
every last line of FFI in it: no `extern "C"`, no `unsafe`, no `struct
linux_dirent64` stepped through by byte offset, no `struct pollfd` assembled in
a `ContiguousBuffer<u8>`. All of it compiled and passed the full suite on the
first attempt, which for a rewrite that touched the daemon's fork, its poll loop
and its HTTP client is a strong statement about the API design. `Child.collect`
polling both pipes rather than draining one and then the other is the kind of
detail that is easy to get wrong by hand and was simply right here.

From before: the borrow checker caught a real use-after-move in this project's
JSON code on the first compile. `manifest { suns: [...] }` multi-file builds and
cross-module `public` visibility worked first try. The JSON module round-tripped
quoting, backslashes, newlines and `\u` escapes correctly with no fuss. The
allocator held flat at 1052 KB RSS across 100k iterations of
`String`/`Vec`/`ContiguousBuffer` churn, which is what made a long-lived daemon
a reasonable thing to write at all. A statically linked 1.3 MB binary with no
runtime dependencies is exactly the right deployment story for a shell
integration.
