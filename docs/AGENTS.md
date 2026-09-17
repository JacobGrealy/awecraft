# docs/ — design essays (scope rules)

- These are **long-form reasoning**: options considered, alternatives rejected, measurements taken.
  They are **not** the source of truth for how the code works today — that is
  `../godot/ARCHITECTURE.md`; operational rules are `../godot/OPS.md` and `../godot/HARNESS.md`.
- `INDEX.md` is the entry point: when you add an essay, add its row (topic + status).
- Some essays are **untracked on purpose** ("local only — not committed" in `INDEX.md`). Never
  `git add` one as a side effect of an unrelated commit.
- When an essay's design ships, the durable outcome belongs in `../godot/ARCHITECTURE.md` or
  `../godot/OPS.md`. Label the essay with what shipped and leave it as history.
- HTML is the house format for these (`INDEX.md` is the only Markdown here).
