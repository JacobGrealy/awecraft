#!/usr/bin/env python3
"""Render / check the GENERATED blocks of godot/HARNESS.md.

`tasks/harness_data.yaml` is the single machine-readable source for the
section-1 mode table and the section-3 known-stable value table. The doc keeps
its prose (intros, run recipes, env knobs, warnings); only those two tables are
generated, between explicit markers:

    <!-- BEGIN GENERATED: modes -->
    <!-- END GENERATED: modes -->
    <!-- BEGIN GENERATED: standing-values -->
    <!-- END GENERATED: standing-values -->

Never hand-edit inside a marker block - `--check` fails on drift:

    python3 tasks/scripts/harness_doc.py --check     # exit 1 when out of sync
    python3 tasks/scripts/harness_doc.py --render    # rewrite the blocks

Why: a .md file must not be both an agent-facing reference and a hard
requirement for a script to run (AC-0301). Scraping THIS doc's markdown was the
old contract - a reformat silently weakened every generated spec. Machine data
lives in the YAML; the doc is a rendering of it.

Deliberate exception: `spec_template.py` still scrapes `godot/autoload/data.gd`
and `godot/world/generator.gd` for constants. That is legitimate - code is a
machine-readable artefact versioned with the behaviour it describes.
"""

import argparse
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DATA = REPO_ROOT / "tasks" / "harness_data.yaml"
DOC = REPO_ROOT / "godot" / "HARNESS.md"

BLOCKS = {
    "modes": ("mode_columns", "modes"),
    "standing-values": ("value_columns", "standing_values"),
}


def _begin(name):
    return "<!-- BEGIN GENERATED: %s -->" % name


def _end(name):
    return "<!-- END GENERATED: %s -->" % name


def load_data(path=DATA):
    with open(path) as fh:
        return yaml.safe_load(fh)


def _row(cells):
    # Matches how the table was authored by hand: a populated cell is padded on
    # both sides ("| x |"), an empty cell stays a single space ("| |").
    return "|" + "|".join((" %s " % c) if c else " " for c in cells) + "|"


def render_modes(data):
    cols = data["mode_columns"]
    out = [_row(cols), "|" + "---|" * len(cols)]
    for name, m in data["modes"].items():
        cells = [
            "`%s`" % name,
            m.get("entry", ""),
            m.get("tests", ""),
            m.get("result_fields", ""),
            m.get("envs", ""),
            m.get("wall", ""),
            m.get("notes", ""),
        ]
        if len(cells) != len(cols):
            raise SystemExit("mode %s: %d cells vs %d columns" % (name, len(cells), len(cols)))
        out.append(_row(cells))
    return "\n".join(out)


def render_standing_values(data):
    cols = data["value_columns"]
    out = [_row(cols), "|" + "---|" * len(cols)]
    for v in data["standing_values"]:
        cells = [v.get("value", ""), v.get("fresh", ""), v.get("established_by", "")]
        if len(cells) != len(cols):
            raise SystemExit("standing value %r: %d cells vs %d columns"
                             % (cells[0], len(cells), len(cols)))
        out.append(_row(cells))
    return "\n".join(out)


def render_block(name, data):
    if name == "modes":
        return render_modes(data)
    if name == "standing-values":
        return render_standing_values(data)
    raise SystemExit("unknown block %s" % name)


def _split_blocks(text):
    """Return [(prefix, name, body, suffix_marker), ...] positions for each block."""
    found = []
    for name in BLOCKS:
        b, e = _begin(name), _end(name)
        if b not in text or e not in text:
            raise SystemExit("markers for %r not found in %s" % (name, DOC.name))
        i = text.index(b) + len(b)
        j = text.index(e)
        if j < i:
            raise SystemExit("markers for %r are out of order" % name)
        found.append((i, j, name))
    found.sort()
    return found


def current_blocks(text):
    return {name: text[i:j].strip("\n") for i, j, name in _split_blocks(text)}


def apply_blocks(text, rendered):
    """Replace each block body with rendered[name]; returns (text, changed_names)."""
    changed = []
    for i, j, name in reversed(_split_blocks(text)):
        body = text[i:j]
        want = "\n" + rendered[name] + "\n"
        if body != want:
            changed.append(name)
        text = text[:i] + want + text[j:]
    return text, list(reversed(changed))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--render", action="store_true", help="rewrite the generated blocks in the doc")
    g.add_argument("--check", action="store_true", help="exit 1 if the doc is out of sync")
    args = ap.parse_args(argv)

    data = load_data()
    doc = DOC.read_text()
    rendered = {name: render_block(name, data) for name in BLOCKS}

    if args.render:
        new, changed = apply_blocks(doc, rendered)
        if changed:
            DOC.write_text(new)
            print("rendered: %s" % ", ".join(changed))
        else:
            print("rendered: already in sync")
        return 0

    changed = []
    for name, got in current_blocks(doc).items():
        if got != rendered[name]:
            changed.append(name)
    if changed:
        print("OUT OF SYNC: %s" % ", ".join(changed))
        print("run: python3 tasks/scripts/harness_doc.py --render")
        for name in changed:
            got_lines = current_blocks(doc)[name].splitlines()
            want_lines = rendered[name].splitlines()
            print("\n--- %s: doc=%d lines, yaml renders=%d lines" %
                  (name, len(got_lines), len(want_lines)))
            for n in range(max(len(got_lines), len(want_lines))):
                a = got_lines[n] if n < len(got_lines) else "<missing>"
                b = want_lines[n] if n < len(want_lines) else "<missing>"
                if a != b:
                    print("  line %d:\n    doc : %s\n    yaml: %s" % (n + 1, a[:160], b[:160]))
                    break
        return 1
    print("in sync: %s" % ", ".join(BLOCKS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
