# godot/world/ — streaming, generation, lighting (scope rules)

What the subsystem *is* — streaming bands, LOD tiers, the scheduler/drain, the save format, the
far/h-only contract — is owned by `../ARCHITECTURE.md` §3/§5/§6. This file owns what a change here
owes, and the traps that cost the most.

## Every change here owes

- **genhash 25/25 byte-identical** (`AWECRAFT_LOGIC=genhash`) whenever `world/*` or
  `autoload/data.gd` was touched. Drift is a finding, not a re-baseline.
- **boundary r4** walk/p95 when streaming or scheduling moved (slow mode: ~46 s wall, 3000 s
  timeout) — standing values in `../HARNESS.md` §3.
- **Standing values** (`../HARNESS.md` §3) after any fluids- or world-touching change.
- The builder runs **at most ONE** boundary r4 probe as a self-check and then exits; the rest is the
  coordinator's background gate job (`awecraft-delegate`, `awecraft-heavy-gates`).

## Traps

- **Bit-exactness is the contract.** Terrain and light must match the reference path exactly: a
  far/h-only column's `H` *is* the height the full path would produce, because promotion must never
  shift terrain. AC-0387 made the far lane actually compute it: `gen_far`/`gen_veg_cells` run the
  full path's per-column sequence (cave-lattice dens_at scan + aquifer + carver — the
  `carved_top_pass`) so the H is the full path's CARVED top and the top row is the post-carve top
  block; the `farab` gate re-pointed at the `carved_tops` binding (the full path's own heff — an
  independent C++ path, not a re-derivation the far lane shares) and is negative-tested (it fails
  on the un-carved build — h_mismatch 3 / 217 bad columns on the 45-column battery). The skip=1
  band-A fill stays un-carved (solid 0..surface_h) — a pre-existing, documented demote/promote
  seam, out of AC-0387's scope. Never re-derive or round a value another lane computes independently
  — compare and assert equality, the way the arms do.
- **A far column is never seeded as all air**, and a far→full promotion re-seeds the **whole**
  column top-down. A stale all-air seam mis-carries sky (a real bug the probe found). The promotion
  contract lives in `../ARCHITECTURE.md` §6 — read it before touching promotion.
- **One accepted full regen per residency**, and a cap-dropped enqueue is a **retry, not a loss**.
- `../../gdext/src/lighting.cpp` (`AweLighting`) and the classic light pull are **test-only
  references**: never wire them into game code. The live engine is `../../gdext/src/starlight.cpp`.
- World constants (`CHUNK` 16, `HEIGHT` 384, `SEA` 126) live in `autoload/data.gd` and are scraped
  into generated specs; changing one moves standing gate values — re-establish them in the same task.
- Saves are format-versioned (v6 today): bump the version when the format changes so an old save is
  **rejected cleanly** — fail fast with a log line and a fresh world, never half-load. The format and the
  **compatibility policy** live in `../ARCHITECTURE.md` §5: **old worlds are disposable during
  development** (user, 2026-09-17), so no migration is owed. The cave series (AC-0288…AC-0292) and
  AC-0293 already assumed it.
- The generator must stay deterministic per seed (default 44) **across the GDScript/C++ boundary** —
  the reason `-ffp-contract=off` is load-bearing in `../../gdext/SConstruct`. See `../../gdext/AGENTS.md`.

Cross-scope: the autoloads that feed generation are `../autoload/AGENTS.md`; the arms that prove this
are `../scenes/AGENTS.md`.
