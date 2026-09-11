#!/usr/bin/env python3
"""AweCraft task registry CLI — the single-writer API for tasks/TASKS.yaml.

All agents MUST mutate the task list through this script only; raw edits to
tasks/TASKS.yaml are forbidden (AC-0254). Every write:

  1. takes the exclusive lock (flock LOCK_EX on <registry dir>/.tasks.lock),
     held across the ENTIRE read-modify-write, released on exit;
  2. dumps the registry in the canonical format (safe_dump-style dumper:
     sort_keys=False, width=100, allow_unicode=True, block style, canonical
     key order — canonical keys first, any other keys such as `comments` in
     their original order, so non-house schemas round-trip as data);
  3. writes atomically (temp file in the registry's directory + os.replace);
  4. re-reads the file and validates: the intended change is present AND
     every other entry (plus queue/meta for commands that do not touch them)
     is data-identical pre vs post. On any mismatch the original file bytes
     are restored and the command exits non-zero.

The first API write re-wraps the file into the canonical style (one-time);
after that, writes of unchanged data are byte-identical (idempotent).
Every mutating command prints a before/after summary line (entries/queue/
meta) after the post-write validation passes.

Read commands (they write nothing; readers are safe because every write is
atomic):
    tasks.py next
    tasks.py list [--status S]
    tasks.py show AC-0254

Mutating commands:
    tasks.py add --title T [--id AC-NNNN] [--source user|agent]
                 [--priority 1|2|3] [--status S] [--labels a,b]
                 [--notes TEXT | --notes-file F | --notes- (stdin)]
                 [--queue head|end|after <ID>]
    tasks.py set --id AC-NNNN [--status S] [--priority 1|2|3]
    tasks.py note --id AC-NNNN (--append-file F | --append- (stdin))
    tasks.py queue add [--at head|end|after] [anchor] <ticket-id>
    tasks.py queue remove <ticket-id>
    tasks.py queue list
    tasks.py status AC-0254 in-progress        (legacy)
    tasks.py comment AC-0254 "text" [--author user|agent]   (legacy)

Every mutation goes through tasks_lib (the shared mutation layer, also used
by tasks/webui.py) so the two cannot drift. TASKS.md no longer exists: the
YAML is the only registry file (removed 2026-08-19 per user), so there is no
markdown re-render step.

The registry file can be pointed at a copy with --file or the
AWECRAFT_TASKS_FILE env var (the sandbox tests use this; the live file is
untouched).
"""

import argparse
import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tasks_lib  # noqa: E402
from tasks_lib import NotFound, TaskError, ValidationFailed  # noqa: F401, E402


def _path(args):
    if getattr(args, "file", None):
        return Path(args.file).expanduser().resolve()
    return tasks_lib.TASKS_PATH


def _parse_place(tokens, flag_name):
    """Parse a queue position spec: head | end | 'after <ID>' (the after form
    may arrive as two tokens or one space-joined token)."""
    if not tokens:
        return None
    if len(tokens) == 1 and tokens[0] in ("head", "end"):
        return tokens[0]
    if len(tokens) == 2 and tokens[0] == "after":
        if not tasks_lib.ID_RE.match(tokens[1]):
            raise TaskError("%s 'after' needs a ticket id, got %r" % (flag_name, tokens[1]))
        return ("after", tokens[1])
    if len(tokens) == 1:
        parts = tokens[0].split(None, 1)
        if len(parts) == 2 and parts[0] == "after" and tasks_lib.ID_RE.match(parts[1]):
            return ("after", parts[1])
    raise TaskError("%s must be head, end, or 'after <ID>'" % flag_name)


def _commit(args, data, original_bytes, original, *, changed_item=None,
            added_id=None, intended=None):
    """Validate-and-commit a mutation under the already-held lock.

    queue/meta touched-ness is derived from the actual before/after state, so
    a command that ends up changing nothing (e.g. `set` with the same value)
    is validated as a data no-op and its write is pure re-wrapping."""
    changed_idx = ()
    if changed_item is not None:
        changed_idx = (data["intake"].index(changed_item),)
    queue_touched = list(data.get("queue") or []) != list(original.get("queue") or [])
    meta_touched = (data.get("meta") or {}) != (original.get("meta") or {})
    return tasks_lib.commit_write(
        _path(args), original_bytes, original, data,
        changed_idx=changed_idx, added_id=added_id,
        queue_touched=queue_touched, meta_touched=meta_touched,
        intended=intended)


def _print_summary(s, added_id=None):
    e = "entries %d -> %d" % (s["entries_before"], s["entries_after"])
    if added_id:
        e += " (+%s)" % added_id
    q = "queue %d -> %d" % (s["queue_before"], s["queue_after"])
    if s["queue_before"] == s["queue_after"]:
        q += " (unchanged)"
    if s["meta_before"] == s["meta_after"]:
        m = "meta unchanged"
    else:
        m = "meta updated_at %s -> %s" % (s["meta_before"].get("updated_at"),
                                          s["meta_after"].get("updated_at"))
    print("summary: %s, %s, %s" % (e, q, m))


# ---------------------------------------------------------------------------
# mutating commands (each: lock -> read -> mutate -> commit+validate)
# ---------------------------------------------------------------------------

def cmd_add(args):
    path = _path(args)
    if args.notes_stdin:
        notes = sys.stdin.read()
    elif args.notes_file:
        p = Path(args.notes_file).expanduser()
        if not p.is_file():
            raise TaskError("no such file: %s" % p)
        notes = p.read_text(encoding="utf-8")
    else:
        notes = args.notes or ""
    place = _parse_place(args.queue, "--queue")
    labels = [s for s in (args.labels or "").split(",") if s.strip()]
    with tasks_lib.registry_lock(path):
        original_bytes, original = tasks_lib.read_registry(path)
        data = tasks_lib.normalize(copy.deepcopy(original))
        item = tasks_lib.add(data, args.title, args.source, args.priority,
                             notes=notes, task_id=args.id, status=args.status,
                             labels=labels)
        queued = None
        if place:
            at, anchor = place if isinstance(place, tuple) else (place, None)
            queued = tasks_lib.queue_insert(data, item["id"], at, anchor)
        def intended(d):
            e = tasks_lib.find_task(d, item["id"])
            if e is None:
                raise TaskError("new entry %s missing after write" % item["id"])
            if (e.get("title") != item["title"] or e.get("status") != item["status"]
                    or e.get("priority") != item["priority"]):
                raise TaskError("new entry %s did not round-trip (title/status/priority)"
                                % item["id"])
            if queued:
                q = d.get("queue") or []
                if item["id"] not in q or q.index(item["id"]) + 1 != queued[0]:
                    raise TaskError("new entry %s not in queue at position %d"
                                    % (item["id"], queued[0]))
        summary = _commit(args, data, original_bytes, original, added_id=item["id"],
                          intended=intended)
    print("Added %s: %s" % (item["id"], item["title"]))
    if queued:
        print("Queued %s at position %d" % (item["id"], queued[0]))
    _print_summary(summary, added_id=item["id"])
    return 0


def cmd_set(args):
    path = _path(args)
    with tasks_lib.registry_lock(path):
        original_bytes, original = tasks_lib.read_registry(path)
        data = tasks_lib.normalize(copy.deepcopy(original))
        item, changed = tasks_lib.set_fields(data, args.id, status=args.status,
                                             priority=args.priority)
        def intended(d):
            e = tasks_lib.find_task(d, args.id)
            if e is None:
                raise TaskError("entry %s missing after write" % args.id)
            if args.status is not None and e.get("status") != args.status:
                raise TaskError("status of %s is %r after write, expected %r"
                                % (args.id, e.get("status"), args.status))
            if args.priority is not None and e.get("priority") != args.priority:
                raise TaskError("priority of %s is %r after write, expected %r"
                                % (args.id, e.get("priority"), args.priority))
        summary = _commit(args, data, original_bytes, original, changed_item=item,
                          intended=intended)
    if args.status is not None:
        print("%s -> %s" % (args.id, item["status"]))
    if args.priority is not None:
        print("%s priority -> %d" % (args.id, item["priority"]))
    if not changed and args.status is None and args.priority is None:
        print("%s: nothing to set (use --status and/or --priority)" % args.id)
    elif not changed:
        print("%s: value already set (no data change)" % args.id)
    _print_summary(summary)
    return 0


def cmd_note(args):
    path = _path(args)
    if args.append_stdin:
        text = sys.stdin.read()
    else:
        p = Path(args.append_file).expanduser()
        if not p.is_file():
            raise TaskError("no such file: %s" % p)
        text = p.read_text(encoding="utf-8")
    with tasks_lib.registry_lock(path):
        original_bytes, original = tasks_lib.read_registry(path)
        data = tasks_lib.normalize(copy.deepcopy(original))
        item = tasks_lib.append_notes(data, args.id, text)
        added = text.rstrip("\n")
        def intended(d):
            e = tasks_lib.find_task(d, args.id)
            if e is None:
                raise TaskError("entry %s missing after write" % args.id)
            n = e.get("notes")
            if not isinstance(n, str) or not n.endswith(added):
                raise TaskError("notes of %s do not end with the appended text" % args.id)
        summary = _commit(args, data, original_bytes, original, changed_item=item,
                          intended=intended)
    print("Appended %d chars to %s notes" % (len(added), args.id))
    _print_summary(summary)
    return 0


def cmd_status(args):
    path = _path(args)
    with tasks_lib.registry_lock(path):
        original_bytes, original = tasks_lib.read_registry(path)
        data = tasks_lib.normalize(copy.deepcopy(original))
        item = tasks_lib.set_status(data, args.id, args.status)
        def intended(d):
            e = tasks_lib.find_task(d, args.id)
            if e is None or e.get("status") != item["status"]:
                raise TaskError("status of %s is %r after write, expected %r"
                                % (args.id, e.get("status") if e else None,
                                   item["status"]))
        summary = _commit(args, data, original_bytes, original, changed_item=item,
                          intended=intended)
    print("%s -> %s" % (args.id, item["status"]))
    _print_summary(summary)
    return 0


def cmd_comment(args):
    path = _path(args)
    with tasks_lib.registry_lock(path):
        original_bytes, original = tasks_lib.read_registry(path)
        data = tasks_lib.normalize(copy.deepcopy(original))
        entry = tasks_lib.find_task(data, args.id)
        comment = tasks_lib.add_comment(data, args.id, args.text, args.author)
        def intended(d):
            e = tasks_lib.find_task(d, args.id)
            if e is None:
                raise TaskError("entry %s missing after write" % args.id)
            ids = [c.get("id") for c in (e.get("comments") or []) if isinstance(c, dict)]
            if comment["id"] not in ids:
                raise TaskError("comment %d not present on %s after write"
                                % (comment["id"], args.id))
        summary = _commit(args, data, original_bytes, original, changed_item=entry,
                          intended=intended)
    print("Comment %d added to %s" % (comment["id"], args.id))
    _print_summary(summary)
    return 0


def cmd_queue(args):
    path = _path(args)
    if args.queue_cmd == "list":
        data = tasks_lib.load_tasks(path)
        for pos, tid in enumerate(data.get("queue") or [], 1):
            item = tasks_lib.find_task(data, tid)
            st = item.get("status") if item else "missing"
            title = item.get("title") if item else "(missing)"
            print("%2d  %s  [%s]  %s" % (pos, tid, st, title))
        return 0
    with tasks_lib.registry_lock(path):
        original_bytes, original = tasks_lib.read_registry(path)
        data = tasks_lib.normalize(copy.deepcopy(original))
        if args.queue_cmd == "remove":
            tid = args.id
            changed = tasks_lib.queue_remove(data, tid)
            def intended(d):
                if tid in (d.get("queue") or []):
                    raise TaskError("%s still in queue after remove" % tid)
            summary = _commit(args, data, original_bytes, original, intended=intended)
            print("%s %s" % ("Unqueued" if changed else "Not in queue", tid))
            _print_summary(summary)
            return 0
        # queue add
        at = args.at
        if at is None:
            if len(args.ids) != 1:
                raise TaskError("queue add expects exactly one ticket id without --at")
            tid = args.ids[0]
            changed = tasks_lib.queue_add(data, tid)
            def intended(d):
                if tid not in (d.get("queue") or []):
                    raise TaskError("%s not in queue after add" % tid)
            summary = _commit(args, data, original_bytes, original, intended=intended)
            pos = data["queue"].index(tid) + 1
            print("%s at position %d" % ("Queued" if changed else "Already queued", pos))
            _print_summary(summary)
            return 0
        anchor = None
        if at in ("head", "end"):
            if len(args.ids) != 1:
                raise TaskError("queue add --at %s expects exactly one ticket id" % at)
            tid = args.ids[0]
            pos, moved = tasks_lib.queue_insert(data, tid, at)
        elif at == "after":
            if len(args.ids) != 2:
                raise TaskError("queue add --at after expects <anchor> <ticket>")
            anchor, tid = args.ids[0], args.ids[1]
            pos, moved = tasks_lib.queue_insert(data, tid, "after", anchor)
        else:
            parts = at.split(None, 1)
            if not (len(parts) == 2 and parts[0] == "after" and len(args.ids) == 1):
                raise TaskError("--at must be head, end, or 'after <id>'")
            anchor, tid = parts[1], args.ids[0]
            pos, moved = tasks_lib.queue_insert(data, tid, "after", anchor)
        at_mode = at if at in ("head", "end", "after") else "after"
        def intended(d):
            q = d.get("queue") or []
            if tid not in q:
                raise TaskError("%s not in queue after add" % tid)
            if at_mode == "head" and q[0] != tid:
                raise TaskError("%s not at the head of the queue after add" % tid)
            if at_mode == "end" and q[-1] != tid:
                raise TaskError("%s not at the end of the queue after add" % tid)
            if at_mode == "after" and (anchor not in q or q.index(tid) != q.index(anchor) + 1):
                raise TaskError("%s not queued directly after %s" % (tid, anchor))
        summary = _commit(args, data, original_bytes, original, intended=intended)
        print("%s %s at position %d" % ("Moved" if moved else "Queued", tid, pos))
        _print_summary(summary)
        return 0
    return 1


# ---------------------------------------------------------------------------
# read commands (write nothing)
# ---------------------------------------------------------------------------

def cmd_next(args):
    data = tasks_lib.load_tasks(_path(args))
    tid = tasks_lib.queue_top(data)
    if tid is None:
        print("next: (queue has no live items)")
        return 0
    item = tasks_lib.find_task(data, tid)
    if item is None:
        print("next: %s (no registry entry)" % tid)
        return 0
    print("next: %s  %s  [%s]" % (tid, item.get("title", ""), item.get("status", "?")))
    return 0


def cmd_list(args):
    data = tasks_lib.load_tasks(_path(args))
    n = 0
    for item in data.get("intake") or []:
        if args.status is not None and item.get("status") != args.status:
            continue
        prio = item.get("priority")
        print("%s  [%s]  p%s  %s" % (item.get("id", "?"), item.get("status", "?"),
                                     prio if prio is not None else "-",
                                     item.get("title", "")))
        n += 1
    print("(%d entries)" % n)
    return 0


def cmd_show(args):
    data = tasks_lib.load_tasks(_path(args))
    item = tasks_lib.find_task(data, args.id)
    if item is None:
        raise NotFound("task %s not found" % args.id)
    sys.stdout.write(tasks_lib.entry_dump(item))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="AweCraft task registry CLI — the single-writer API for tasks/TASKS.yaml",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("--file", default=None, help="alternative TASKS.yaml path "
                        "(default: env AWECRAFT_TASKS_FILE or tasks/TASKS.yaml)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("add", help="add a new intake entry")
    p.add_argument("--title", required=True)
    p.add_argument("--id", default=None, help="explicit id (default: next free AC-NNNN)")
    p.add_argument("--source", choices=tasks_lib.SOURCES, default="user")
    p.add_argument("--priority", type=int, default=2, choices=tasks_lib.PRIORITIES)
    p.add_argument("--status", choices=tasks_lib.STATUSES, default="open")
    p.add_argument("--labels", default="", help="comma-separated labels")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--notes", default=None)
    g.add_argument("--notes-file", dest="notes_file", default=None)
    g.add_argument("--notes-", dest="notes_stdin", action="store_true",
                   help="read notes from stdin")
    p.add_argument("--queue", nargs="+", default=None, metavar="POS",
                   help="also place it in the queue: head | end | after <ID>")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("set", help="set status and/or priority")
    p.add_argument("--id", required=True)
    p.add_argument("--status", choices=tasks_lib.STATUSES, default=None)
    p.add_argument("--priority", type=int, default=None, choices=tasks_lib.PRIORITIES)
    p.set_defaults(fn=cmd_set)

    p = sub.add_parser("note", help="append text to an entry's notes")
    p.add_argument("--id", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--append-file", dest="append_file", default=None)
    g.add_argument("--append-", dest="append_stdin", action="store_true",
                   help="read the text to append from stdin")
    p.set_defaults(fn=cmd_note)

    p = sub.add_parser("show", help="pretty-print one entry")
    p.add_argument("id")
    p.set_defaults(fn=cmd_show)

    pq = sub.add_parser("queue", help="work-order queue management")
    qsub = pq.add_subparsers(dest="queue_cmd", required=True)
    qa = qsub.add_parser("add", help="queue a ticket (default: append at end)")
    qa.add_argument("--at", default=None,
                    help="head | end | after <anchor> (after takes <anchor> <ticket>)")
    qa.add_argument("ids", nargs="+")
    qa.set_defaults(fn=cmd_queue)
    qr = qsub.add_parser("remove", help="remove a ticket from the queue")
    qr.add_argument("id")
    qr.set_defaults(fn=cmd_queue)
    ql = qsub.add_parser("list", help="print the queue")
    ql.set_defaults(fn=cmd_queue)

    p = sub.add_parser("next", help="print the next live queue item")
    p.set_defaults(fn=cmd_next)

    p = sub.add_parser("list", help="list intake entries")
    p.add_argument("--status", choices=tasks_lib.STATUSES, default=None)
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("status", help="change a task's status (legacy)")
    p.add_argument("id")
    p.add_argument("status", choices=tasks_lib.STATUSES)
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("comment", help="add a comment to a task (legacy)")
    p.add_argument("id")
    p.add_argument("text")
    p.add_argument("--author", choices=tasks_lib.SOURCES, default=None,
                   help="prefix the comment with [user]/[agent] (registry convention)")
    p.set_defaults(fn=cmd_comment)

    args = parser.parse_args(argv)
    try:
        if args.cmd == "set" and args.status is None and args.priority is None:
            print("error: set needs --status and/or --priority", file=sys.stderr)
            return 2
        return args.fn(args)
    except (NotFound, TaskError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
