# Sun feedback, as issue drafts

Each section below is a self-contained issue body, ready to file against the
[Sun](https://namo-robotics.github.io/sun/) repository — repro, observed
behaviour, expectation, impact. They come out of writing
[`namo_complete`](https://github.com/namo-robotics/namo_complete), an
LLM-powered bash completion tool: ~1900 lines of Sun, an FFI-heavy program with
a network client, a file cache and a long-lived daemon.

Every repro is standalone, and every one was re-run against the build named in
its Environment line before this was written. Items fixed in earlier compiler
builds have been dropped along with the workarounds they forced.

Ordered by severity: compiler crashes, then things that shaped the
architecture, then papercuts.

---

## 1. Compiler crashes (SIGTRAP, no diagnostic) when a `void` result is bound to an inferred `var`

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux, `sun -c` (static AOT).

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

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux, `sun -c` (static AOT).

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
  call void @"$d8d0890e$_sun_String_trim"(ptr %method.closure1, %"$d8d0890e$_sun_HeapAllocator_struct" %move.val)
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
name. This is a likely mistake whenever an API changes shape — a method that
used to take an allocator and no longer does, say — which is exactly when a
clear message matters most.

---

## 3. `static_ptr<u8>` parameters make core stdlib APIs unusable for computed values

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`static_ptr<u8>` is satisfied only by compile-time literals, and nothing can
construct one at runtime. Several stdlib entry points take paths and messages
that way, which makes them unusable for any value the program computes:

| API | Signature | Consequence |
|---|---|---|
| `File.open` (io.sun:41) | `path: static_ptr<u8>` | cannot open a path you computed |
| `remove_file` (io.sun:135) | `path: static_ptr<u8>` | same |
| `make_dir` (io.sun:151) | `path: static_ptr<u8>` | same |
| `Error` (errors.sun:27) | `message: static_ptr<u8>` | an `IError` cannot carry the failing path or errno |

**Repro**

```sun
using sun;
using sun.io;

function main() i32 {
  var alloc = make_heap_allocator();
  var path = String(alloc, "/tmp/");
  path.append("computed.txt");
  var f = File();
  try { f.open(path, 1); } catch (e: IError) { }
  return 0;
}

manifest { moons: ["stdlib.moon"] }
```
```
Error: fo.sun:8:9: Type mismatch in argument 1 of call to '<unknown>':
       expected static_ptr(u8), got String
```

The same for a computed error message:

```sun
function boom(path: ref String) void, IError {
  throw Error(-1, path);
}
```
```
Error: e.sun:3:9: No matching constructor for '$d8d0890e$_sun_Error'
       with arguments (i32, ref(String))
```

**Expected:** a `ref String` overload on each of these.

**Requested:** `File.open`, `remove_file` and `make_dir` accepting `ref String`,
and an `Error` constructor accepting an owned or borrowed `String`.

**Impact:** a program that computes every path it touches — `$XDG_RUNTIME_DIR`,
`$XDG_CACHE_HOME`, a hashed cache filename, a per-shell FIFO — cannot use
`sun.io` at all. `namo_complete` reimplements
`open`/`read`/`write`/`close`/`unlink`/`mkdir` over libc in
[`src/fs.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/fs.sun)
purely so the calls accept a `ref String`. That file exists for no other reason
and a `ref String` overload would delete it outright. Dynamic error payloads
would likewise turn a pile of "carry the detail out-of-band" plumbing into
ordinary `throw`s.

Side note: the diagnostic says `call to '<unknown>'` rather than naming
`File.open`.

---

## 4. No `String` → C string bridge, so every FFI call hand-rolls a copy

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`String.data` is private (string.sun:84) and `ContiguousBuffer.rawData()` makes
no NUL-termination guarantee, so there is no supported way to hand a `String` to
a C function.

**Repro**

```sun
using sun;

extern "C" function puts(s: raw_ptr<u8>) i32;

function main() i32 {
  var alloc = make_heap_allocator();
  var s = String(alloc, "hello");
  unsafe { puts(s.data.get_raw()); };
  return 0;
}

manifest { moons: ["stdlib.moon"] }
```
```
Semantic Error: c.sun:6:17: 'data' is private to class 'String' in module 'sun'
                and cannot be accessed here
```

**Workaround** — every caller writes this out by hand:

```sun
var buf = ContiguousBuffer<u8>(alloc, n + 1);
for (var i: i64 = 0; i < n; i = i + 1) { buf.set_unchecked(i, s.at(i)); }
buf.set_unchecked(n, 0);
```

**Requested:** `String.as_cstr()` returning a NUL-terminated view, or a `CStr`
type with an explicit lifetime relationship to its `String`.

**Impact:** this is the single most-used function in `namo_complete` — every
file open, every `getenv`, every `chdir`, every write goes through it. It is the
entire contents of
[`src/cstr.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/cstr.sun),
which `String.as_cstr()` would delete.

---

## 5. No macOS target: `extern "C"` is ELF-only, which blocks distribution entirely

**Environment:** `sun 0.dev (14b37d81f2ae)`, building on x86_64 Linux.

A program that uses the FFI cannot be built for macOS at all.

**Repro** — any program containing an `extern "C"` declaration:

```
$ sun -c --target aarch64-apple-darwin -o out prog.sun
Error: no C ABI rules for target 'aarch64-apple-darwin';
       extern "C" supports x86_64 and aarch64 (ELF) only
```

`x86_64-apple-darwin` gets past the ABI check and then fails at link.

**Requested:** Mach-O argument classification and an `aarch64-apple-darwin` ABI.

**Impact:** because issues #3 and #7 force *every* file operation and every
environment read through the FFI, there is no subset of the program that still
works without it — this is not something an application can design around.
`namo_complete` is therefore Linux-only, and its published releases are Linux
x86_64 only. For anyone shipping a Sun program to end users, this is the single
highest-impact addition.

Adjacent: upstream publishes only `sun_0.dev_amd64.deb`, so there is no macOS
toolchain to build with either.

---

## 6. No TLS, so any HTTPS client has to shell out

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`networking.sun` provides raw IPv4 TCP and `http.sun` provides a plaintext HTTP
*server*. There is no HTTPS client and no TLS socket anywhere in the stdlib
(`grep -l 'tls\|TLS\|SSL' stdlib/*.sun` returns nothing).

**Requested:** an HTTPS client, or failing that, TLS sockets to build one on.

**Impact:** for a program whose entire job is calling an HTTPS API, the whole
transport becomes a subprocess wrapper around the `curl` binary — write the body
to a file, write a mode-0600 curl config, `chdir`, `system("curl -sS -K
./req.conf ...")`, read the response back
([`src/client.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/client.sun)).
That is ~150 lines and a runtime dependency on an external binary, in a language
whose static-linking story is otherwise its best feature.

FFI to libcurl was considered and rejected: Sun links statically by default,
libcurl commonly ships as a `.so` only (needing `--dynamic` plus a `-dev`
package), and **Sun's FFI rejects function pointers**, which rules out libcurl's
write-callback API.

---

## 7. No process, directory or environment access in the stdlib

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`getenv`, `system`, `chdir`, `getuid`, `time` and reading stdin have no stdlib
equivalent and are hand-declared FFI. Writing a long-lived helper process added
`fork`, `setpgid`, `dup2`, `poll`, `getpid` and `getdents64` to the same list.
Two of those gaps are more than a convenience problem:

- **No directory enumeration.** Nothing in the stdlib walks a directory. The
  workaround is `getdents64`, which hands back a packed `struct linux_dirent64`
  that has to be stepped through by byte offset (`d_reclen` is the `u16` at 16,
  `d_name` starts at 19) because the FFI cannot describe a C struct. It works,
  but it puts Linux-specific record parsing in application code.
- **No `poll`/`select`.** Waiting on a descriptor with a timeout is the entire
  shape of a debounce loop. `struct pollfd` has to be built by hand in a
  `ContiguousBuffer<u8>`, filled with `_store<i32>` plus individual byte writes,
  and read back the same way.

Command-line arguments are reachable (`main(argc, argv)` — `src/driver.cpp`
checks `mainArgCount == 2`), but the parameter types are undocumented and every
example in the docs uses a bare `main()`. `namo_complete` uses environment
variables instead, partly for this reason.

**Requested:** a `sun.process` module covering `fork`/`exec`/`poll`/`getenv`, and
a `read_dir(path)` returning `Vec<String>`.

**Impact:** most of the FFI block in
[`src/live.sun`](https://github.com/namo-robotics/namo_complete/blob/main/src/live.sun)
exists only to fill these gaps.

---

## 8. A `ref` local cannot be bound to a class field

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

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

## 9. No narrowing conversion between integer types

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

There is no cast and no truncating intrinsic from `i64` to `i32`. `_bitcast<T>`
covers only same-width reinterpretation (`f32` ↔ `u32`), so it does not apply.

**Repro**

```sun
var ms: i64 = 200;
var t: i32 = ms;
```
```
Error: n.sun:5:3: Cannot assign value of type 'i64' to variable 't' of type 'i32'
```

**Requested:** an explicit narrowing cast, or a `_truncate<T>` intrinsic.

**Impact:** this bites hardest at the FFI boundary, where C's `int` is
everywhere. `poll(2)`'s timeout is an `int`, and a debounce interval naturally
computes as `i64`. With no way to narrow, the workaround is to declare the
parameter `i64` and rely on the SysV rule that the callee reads only the low
half of the register:

```sun
extern "C" function poll(fds: raw_ptr<u8>, nfds: i64, timeout: i64) i32;
```

That is correct, but the language should not make knowing that rule a
prerequisite for calling libc.

---

## 10. `String.split` keeps empty pieces, and there is no whitespace-collapsing helper

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`String.split(alloc, sep)` (string.sun:682) emits an entry for every separator
including runs and trailing separators, so splitting text into lines or words
means writing a filter at every call site.

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

## 11. `partial` is a reserved word, with a diagnostic that does not say so

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

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

## 12. `&&` / `||` produce a parse error that does not suggest `and` / `or`

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

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

## 13. `Json(...)` takes ownership of its `String`, which is not documented

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`Json(s: String)` (json.sun:102) consumes the string, so any value still needed
after being placed into a document has to be cloned first:

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

## 14. Stdlib renames ship with no deprecation window or changelog

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

`Vec.borrow_unchecked` became `Vec.get_unchecked` between builds, with no
deprecation period and no release note. It broke this project's build outright,
and the only way to find out what changed was to diff the stdlib sources.

**Requested:** a changelog, or release notes listing stdlib renames.

**Impact:** upgrading the compiler is currently an unbounded task — there is no
way to know what will break before trying it. That discourages tracking `dev`,
which is where the fixes are.

---

## 15. `_static_ptr_data` / `_static_ptr_len` are documented as discouraged, but are the only option

**Environment:** `sun 0.dev (14b37d81f2ae)`, x86_64 Linux.

The docs describe `_static_ptr_data<T>` and `_static_ptr_len<T>` as intrinsics
to avoid, yet they are the only way to do anything with a `static_ptr` value —
and the stdlib's own public API hands `static_ptr<u8>` parameters to callers
routinely (see issue #3).

**Requested:** either a supported accessor for `static_ptr`, or documentation
acknowledging that these intrinsics are the intended tool for it.

**Impact:** application code has to use an intrinsic the documentation warns
against, with no way to tell whether it will keep working.

---

## Not an issue: what already works well

Worth recording alongside the list above. The borrow checker caught a real
use-after-move in this project's JSON code on the first compile.
`manifest { suns: [...] }` multi-file builds and cross-module `public`
visibility worked first try. The JSON module round-tripped quoting,
backslashes, newlines and `\u` escapes correctly with no fuss. `extern "C"`
against libc behaved identically under JIT and static-musl AOT, and `fork` and
`poll` over that FFI worked first try in a statically linked binary. The
allocator held flat at 1052 KB RSS across 100k iterations of
`String`/`Vec`/`ContiguousBuffer` churn, which is what made a long-lived daemon
a reasonable thing to write at all. A statically linked 1.3 MB binary with no
runtime dependencies is exactly the right deployment story for a shell
integration.
