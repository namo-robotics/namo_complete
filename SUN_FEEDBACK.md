# What would make this easier in Sun

Notes from writing `namo_complete`, originally against `sun 0.dev
(d3e45234670e)` and re-checked against `sun 0.dev (d1b779771504)`. Every item
below cost real work in this repo, and each cites the file that forced the
workaround so it can be reproduced. Ordered by how much code it would delete
here.

---

## Fixed in `d1b779771504`

The four correctness bugs originally reported here are gone, and every
workaround they forced has been removed from this repo. Kept for the record,
with the behaviour observed on the current compiler.

### 1. `u8 + <integer literal>` miscompiled — **fixed**

Adding a bare integer literal to a `u8` used to promote to `i32` and never
narrow back: `c = c + 32` silently compiled into a binary that spun forever, and
`append_char(c + 32)` failed LLVM verification. Both now compile and produce the
right answer, so `src/util.sun` (`to_lower`) no longer needs to park the addend
in a `u8`-typed variable.

### 2. `using sun;` at file scope silently miscompiled — **fixed**

A file whose `using sun;` sat outside the module block used to print
`Failed to instantiate generic type 'Vec'`, then exit 0 and ship a hanging
executable. It is now a hard error with a diagnostic that says what to do:

```
Unknown generic type 'Vec'. No generic class, interface or enum by that name is
visible here — check the spelling, and that the module declaring it is imported
in this scope.
```

`using sun;` still has to live inside the module block, but the build fails
instead of shipping.

### 3. Borrow checker is now flow-sensitive across branches — **fixed**

An early `return` of an owned value used to mark it moved on *every* path,
including mutually exclusive ones, which ruled out ordinary guard clauses. This
now compiles and runs correctly:

```sun
var out = Vec<String>(alloc, 4);
try { raw = read_file(alloc, path); }
catch (e: IError) { return out; }
if (lines.size() < 2) { return out; }
```

`cache_lookup` in `src/cache.sun` has been rewritten from its single-exit-point,
`ok`-flag shape into plain guard clauses.

### 4. Assigning a class field moves it — **now diagnosed**

Reading a `String` field into a local still moves it out of the object, but it
is no longer silent; the *use* after the move is rejected at compile time:

```
error: use of moved field 'cfg.line'. It was moved out of its object; assign a
value back into it before reading it again
```

That turns what was a runtime mystery (the program called the API with an empty
`<request>` because a field had been read into a local earlier) into a build
failure. Passing the field as a `ref String` parameter borrows rather than
moves, which is what `src/main.sun` now does — no intermediate copy needed. A
`ref` local bound to a field (`var s: ref String = cfg.line;`) is still
rejected, so a conditional borrow needs the branch duplicated.

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

Moving the as-you-type watcher out of bash and into the binary (`src/live.sun`)
added `fork`, `setpgid`, `dup2`, `poll`, `getpid` and `getdents64` to that list.
Two of those are more than convenience gaps:

- **No directory enumeration.** Nothing in the stdlib walks a directory, and
  `getdents64` hands back a packed `struct linux_dirent64` that has to be
  stepped through by byte offset (`d_reclen` is the u16 at 16, `d_name` starts
  at 19) because the FFI cannot describe a C struct. It works, but it puts
  Linux-specific record parsing in application code.
- **No `poll`/`select`.** Waiting on a descriptor with a timeout is the entire
  shape of a debounce loop. `struct pollfd` is built by hand in a
  `ContiguousBuffer<u8>`, filled with `_store<i32>` and individual byte writes,
  and read back the same way.

A `sun.process` module with `fork`/`poll`, and a `read_dir(path)` returning
`Vec<String>`, would delete most of `src/live.sun`'s FFI block.

### 10. No string utilities — **largely fixed in `d1b779771504`**

At the time of writing, `String` had no `split`, `substring`, `trim`, `replace`,
or case conversion — only `find_char`/`rfind_char` and slicing to a
`StringView` — so `src/util.sun` hand-rolled `trim`, `split_lines`, `to_lower`,
`contains_lit`, `append_hex_i64`, and `normalize_ws`, and substring search
against a literal went through the `_static_ptr_data` / `_static_ptr_len`
intrinsics.

`d1b779771504` adds `trim`/`trim_start`/`trim_end`, `to_lower`/`to_upper`,
`find`, `contains`, `replace`, `split`, `substr`, `clone`, `append_hex`, and a
free `join`. `src/util.sun` now uses them and is less than half its former size:
`trim`, `to_lower`, `contains_lit`, `append_hex_i64` and `clone_str` are gone
outright, `split_lines` is a wrapper around `String.split`, and the intrinsics
are no longer needed outside `src/sysexec.sun`. Only `normalize_ws` (collapse
whitespace runs) has no stdlib equivalent.

Two things worth documenting: the mutating methods return `void` and edit in
place, so the obvious `var t = s.trim(alloc);` type-errors on `void`; and
`String.split(alloc, sep)` keeps empty pieces, so callers that want
`split_lines` semantics still have to filter.

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
- **`Vec.borrow_unchecked` was renamed to `get_unchecked`** in `d1b779771504`
  with no deprecation window, which broke this repo's build outright. A
  changelog entry, or a `sun` release note listing stdlib renames, would make
  compiler upgrades cheaper.
- **No integer narrowing conversion.** There is no cast and no truncating
  intrinsic from `i64` to `i32`; `_bitcast<T>` only covers same-width
  reinterpretation. `poll(2)`'s timeout is an `int`, so `src/live.sun` declares
  the parameter `i64` and relies on the SysV rule that the callee reads only the
  low half of the register. That is correct, but the language should not make
  knowing it a prerequisite for calling libc.
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
`fork` and `poll` over the FFI worked first try in a statically linked binary,
and the allocator held flat at 1052 KB RSS across 100k iterations of
String/Vec/ContiguousBuffer churn — which is what made a long-lived daemon a
reasonable thing to write at all.
