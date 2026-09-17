# gdext/ — the C++ GDExtension (scope rules)

The lanes, their roles and the loading path are owned by `../godot/ARCHITECTURE.md` §4. This file
owns the build traps and the invariants that keep the native side honest.

## Build

```bash
python3 -m SCons -C gdext platform=linux   target=template_release   # local gates load this .so
python3 -m SCons -C gdext platform=windows target=template_release   # the product .dll
./build_windows.sh                                                   # both, then export + serve
```

- **godot-cpp must be built first**, from its own directory: the SConstruct default is
  `<repo>/.scratch/godot-cpp` (`GODOT_CPP` overrides it). Building it from `gdext/` fails with
  "Argument list too long", so run it where its object paths stay relative, with `-j6`:
  `cd .scratch/godot-cpp && python3 <scons> target=template_release -j6`
- Windows is a **MinGW-w64 cross-compile** on this box. The `.dll` must keep the `.gdextension`
  convention name `libchunkio.windows.template_release.x86_64.dll`, and the static
  libgcc/libstdc++ link flags are deliberate — leave them alone.
- **Rebuild after every C++ edit.** Local gates load `godot/bin/libchunkio.so`; a stale `.so`
  silently gates the *old* code. Re-running an arm does not rebuild anything.
- `gdext/bin/` and `godot/bin/*` are **build outputs** — git-ignored, never committed. A fresh
  worktree or clone has none, so headless startup cannot parse the extension: copy the `.so` from
  the main tree (`../godot/OPS.md` §2).

## Invariants

- **The extension is required** (AC-0208): a missing class makes `Game` print the CANNOT START banner
  and quit. There is no GDScript fallback lane — the surviving GDScript kernels are probe-only
  references behind sentinels, and the `nofallback` arm is the standing proof that the C++ lanes
  carry the work.
- A new `src/*.cpp` is picked up by the SCons glob, but its class must be **registered in the entry
  symbol** (`chunkio_library_init` in `src/awe_common.cpp`) and documented in
  `../godot/ARCHITECTURE.md` §4 in the same task.
- `src/lighting.cpp` (`AweLighting`) is a **test-only reference** (AC-0283 P4 / AC-0297): never wire
  it into game code. The live light engine is `src/starlight.cpp`.
- **`-O2 -ffp-contract=off` is load-bearing** (AC-0188): the AweNoise port must stay bit-identical to
  the GDScript reference, so never enable FMA, fast-math, or let contraction fold the fade/ramp
  polynomials. That would silently break genhash parity — `../godot/world/AGENTS.md`.
- `libchunkio` is a historical name: it now covers generation, meshing, strips, chunk I/O and lighting.
