# What would make this easier in Sun

Notes from writing `namo_complete` against `sun 0.dev (d3e45234670e)`. Every item
below cost real work in this repo, and each cites the file that forced the
workaround so it can be reproduced. Ordered by how much code it would delete
here, except for the correctness bugs, which come first.

---

## Correctness bugs

These produce wrong behaviour rather than a diagnostic, which makes them
expensive to find.

### 1. `u8 + <integer literal>` miscompiles

Adding a bare integer literal to a `u8` promotes to `i32` and never narrows
back. Two distinct symptoms:

```sun
// (a) Silently compiles, then hangs forever at runtime.
var c: u8 = s.at(i);
if (c >= 65 and c <= 90) { c = c + 32; }
out.append_char(c);

// (b) Fails LLVM verification at compile time.
out.append_char(c + 32);
//   call void @..._append_char$u8(ptr %closure, i32 %addtmp)
//   Error: Function verification failed
```

Variant (a) is the dangerous one: `sun -c` reports success and emits a binary
that spins. Keeping the addend in a `u8` variable is the workaround:

```sun
var delta: u8 = 32;
c = c + delta;        // fine
```

Case (b) at least fails loudly, but the message points at generated IR rather
than the source expression. *Workaround in `src/util.sun` (`to_lower`).*

### 2. `using sun;` at file scope silently miscompiles

A file whose `using sun;` sits outside the module block still parses, but
generic instantiation fails and the compiler emits a **binary that hangs**:

```sun
using sun;                       // <-- outside the block: broken
public module namo {
  public function f(a: ref HeapAllocator) Vec<String> { ... }
}
```
```
Error: Unknown generic class 'Vec'
Error: Failed to instantiate generic type 'Vec'
...
Successfully compiled to: bin/namo_complete    <-- exit code 0
```

Moving `using sun;` inside the block fixes it. The problem is that
`Failed to instantiate generic type` is printed but **not treated as fatal** —
the build "succeeds" and ships a hanging executable. Whatever the scoping
decision, this should be a hard error.

### 3. Borrow checker is not flow-sensitive across branches

An early `return` of an owned value marks it moved on *every* path, including
mutually exclusive ones:

```sun
var out = Vec<String>(alloc, 4);
try { raw = read_file(alloc, path); }
catch (e: IError) { return out; }     // move
if (lines.size() < 2) { return out; } // error: use of moved variable 'out'
```

So the ordinary guard-clause style does not compile, and functions must be
rewritten around a single exit point with `ok` flags. *Workaround in
`src/cache.sun` (`cache_lookup`).*

### 4. Assigning a class field moves it, silently

Reading a `String` field into a local variable moves it out of the object and
leaves the field empty, with no borrow-check error at the assignment:

```sun
var subject = cfg.line;          // moves the field
if (cfg.is_ask()) {
  subject = cfg.query;           // moves this one too
}
// ... later, cfg.query is now empty
var context = build_context(alloc, cfg, ...);   // sends an empty <request>
```

This cost real debugging time: the program compiled, ran, called the API, and
produced a confused answer from the model because a field it had already read
had been silently emptied. Given the borrow checker rejects a *use* after move
(§3), it is surprising that a move *out of a field* is accepted at all -- either
rejecting it, or copying, would have caught this at compile time. Workaround is
to append into a fresh `String` instead of assigning.

---

## Blockers that shaped the architecture

### 5. `static_ptr<u8>` parameters make stdlib APIs literal-only

`static_ptr<u8>` is satisfied only by compile-time literals, and nothing can
construct one at runtime. That makes several stdlib APIs unusable for computed
values:

| API | Signature | Consequence |
|---|---|---|
| `File.open` (io.sun:41) | `path: static_ptr<u8>` | **Cannot open a path you computed** |
| `remove_file` (io.sun:135) | `path: static_ptr<u8>` | same |
| `make_dir` (io.sun:151) | `path: static_ptr<u8>` | same |
| `Error` (errors.sun:25) | `message_: static_ptr<u8>` | An `IError` cannot carry the failing path or errno |

Because a completion tool computes every path it touches (`$XDG_RUNTIME_DIR`,
`$XDG_CACHE_HOME`, a hashed cache filename), **`sun.io` could not be used at
all** — `src/fs.sun` reimplements `open`/`read`/`write`/`close`/`unlink`/`mkdir`
over libc purely to accept a `ref String` path.

*A `ref String` overload on these APIs would delete `src/fs.sun` outright.*
Dynamic error payloads would likewise turn our "carry detail out-of-band"
plumbing into ordinary `throw`s.

### 6. No `String` → C string bridge

`String.data` is not `public` (string.sun:70), and `ContiguousBuffer.rawData()`
makes no NUL-termination guarantee, so every FFI call needs a hand-rolled copy:

```sun
var buf = ContiguousBuffer<u8>(alloc, n + 1);
for (var i: i64 = 0; i < n; i = i + 1) { buf.set_unchecked(i, s.at(i)); }
buf.set_unchecked(n, 0);
```

A `String.as_cstr()` (or a `CStr` type) would delete `src/cstr.sun`. This is
the single most-used function in the project.

### 7. No macOS target (blocks distribution entirely)

`extern "C"` supports ELF only, so a program that uses the FFI cannot be built
for macOS at all:

```
$ sun -c --target aarch64-apple-darwin -o out prog.sun
Error: no C ABI rules for target 'aarch64-apple-darwin';
       extern "C" supports x86_64 and aarch64 (ELF) only
```

`x86_64-apple-darwin` gets past the ABI check and then fails at link. Because
§5 and §8 force *every* file operation and environment read through the FFI,
this is not a limitation we can design around -- there is no subset of the
program that still works. `namo_complete` is therefore Linux-only, and the
published releases are Linux x86_64 only.

Mach-O argument classification (and an aarch64-apple-darwin ABI) would be the
single highest-impact addition for anyone shipping a Sun program to end users.
Adjacent: upstream publishes only `sun_0.dev_amd64.deb`, so there is no macOS
toolchain to build with either.

### 8. No TLS

`networking.sun` provides raw IPv4 TCP and `http.sun` a plaintext HTTP
*server*; there is no HTTPS client. Since this program's whole job is calling
an HTTPS API, the entire transport (`src/client.sun`) is a subprocess wrapper
around the `curl` binary: write the body to a file, write a mode-0600 curl
config, `chdir`, `system("curl -sS -K ./req.conf ...")`, read the response back.

FFI to libcurl was considered and rejected: Sun links statically by default,
libcurl commonly ships as a `.so` only (needing `--dynamic` plus a `-dev`
package), and **Sun's FFI rejects function pointers**, which rules out
libcurl's write-callback API.

*An HTTPS client — or even just TLS sockets — removes ~150 lines and a runtime
dependency on an external binary.*

### 9. No process/environment/stdin in the stdlib

`getenv`, `system`, `chdir`, `getuid`, `time`, and reading stdin are all
hand-declared FFI in `src/sysexec.sun` and `src/fs.sun`. Command-line arguments
are reachable (`main(argc, argv)` — `src/driver.cpp` checks `mainArgCount == 2`),
but the parameter types are undocumented; every example in the docs uses bare
`main()`. We used environment variables instead, partly for this reason.

### 10. No string utilities

`String` has no `split`, `substring`, `trim`, `replace`, or case conversion —
only `find_char`/`rfind_char` and slicing to a `StringView`. `src/util.sun`
implements `trim`, `split_lines`, `to_lower`, `contains_lit`, and `normalize_ws`
by hand. Substring search against a literal needs the `_static_ptr_data` /
`_static_ptr_len` intrinsics, which reads as surprisingly low-level for
"does this string contain that one".

---

## Papercuts

- **`partial` is a reserved word**, with a confusing diagnostic
  (`expected identifier after 'var'`) and no mention in the docs. A "reserved
  word" message, or a keyword list in the docs, would save the bisect.
- **`&&` / `||` are not accepted** — Sun uses `and` / `or`. Reasonable, but the
  parse error (`unknown token when expecting an expression`) does not suggest
  the alternative.
- **`Json(...)` takes ownership of its `String`**, so building a request means
  cloning strings that are still needed. Worth calling out in the JSON docs.
- **`_static_ptr_data<T>` / `_static_ptr_len<T>` are documented as discouraged
  intrinsics**, yet they are the only way to work with a `static_ptr` parameter
  — which the stdlib's own public API hands you routinely.

## What already works well

Worth saying, since the list above is all complaints: the borrow checker caught
a real use-after-move in our JSON code on the first compile; `manifest { suns: [...] }`
multi-file builds and cross-module `public` visibility worked first try; the
JSON module round-tripped quoting, backslashes, newlines, and `\u` escapes
correctly with no fuss; `extern "C"` against libc worked identically under JIT
and static-musl AOT; and a statically linked 1.3 MB binary with no runtime
dependencies is exactly the right deployment story for a shell integration.
