# tasks/scripts/ — the tooling (scope rules)

- **`../harness_data.yaml` is the machine source** for the `godot/HARNESS.md` §1 mode table and §3
  standing values. A doc must not double as a script's data file (AC-0301). Edit the data, then:

  ```bash
  python3 tasks/scripts/harness_doc.py --render   # rewrite the generated blocks
  python3 tasks/scripts/harness_doc.py --check    # exit 1 + first diff when out of sync
  ```

  Never hand-edit inside `BEGIN/END GENERATED` markers.
- **Never couple a script to a document's markdown.** Scraping *code* stays legitimate — it is a
  machine-readable artefact versioned with the behaviour it describes — which is why `spec_template.py`
  still reads constants from `godot/autoload/data.gd` and `godot/world/generator.gd` on purpose.
- **`python3 tasks/scripts/test_tasks.py` must stay green (53 checks).** Run it after touching
  `tasks.py`, `tasks_lib.py`, `spec_template.py`, `harness_doc.py`, `render.py` or `webui.py`. It works
  against copies of the registry under `.scratch/` and never writes the live `tasks/TASKS.yaml`.
- `tasks.py` + `tasks_lib.py` are the single-writer API (lock → canonical dump → atomic replace →
  validate). A schema change must keep existing entries round-tripping: the dump is byte-stable by
  design, so unchanged data must stay byte-identical.
- `spec_template.py` generates `tasks/AC-NNNN/spec.html`. Keep the **default slim** (path pointers) —
  the mode/value tables are lookups, not reading material; `--full` exists for when they are needed.
- `render.py` and `webui.py` share the board layout, so the saved view and the live board can never
  disagree. `python3 tasks/webui.py --daemon` serves the LAN board on `:5180` (`--replace` reclaims the
  port from a stale instance; without it, an already-running instance exits 0).
