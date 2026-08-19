#!/usr/bin/env python3
"""AweCraft task registry CLI.

Usage:
    tasks.py add --title "Fix the bug" --source user --priority 1 --notes "why"
    tasks.py status AC-0046 in-progress|open|blocked|done
    tasks.py comment AC-0046 "root cause was X" --author agent
    tasks.py queue add AC-0031
    tasks.py queue remove AC-0031
    tasks.py queue list
    tasks.py next

Every mutation goes through tasks_lib (the shared mutation layer, also used by
tasks/webui.py) so the two cannot drift. TASKS.md no longer exists: the YAML is
the only registry file (removed 2026-08-19 per user), so there is no markdown
re-render step.

The registry file can be pointed at a copy with --file or the
AWECRAFT_TASKS_FILE env var (the sandbox test uses this).
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tasks_lib
from tasks_lib import NotFound, TaskError  # noqa: E402


def _load(args):
    path = Path(args.file).expanduser().resolve() if getattr(args, "file", None) else None
    return tasks_lib.load_tasks(path)


def _save(data, args):
    path = Path(args.file).expanduser().resolve() if getattr(args, "file", None) else None
    tasks_lib.save_tasks(data, path)


def cmd_add(args):
    data = _load(args)
    item = tasks_lib.add(data, args.title, args.source, args.priority, args.notes)
    _save(data, args)
    print("Added %s: %s" % (item["id"], item["title"]))
    return 0


def cmd_status(args):
    data = _load(args)
    item = tasks_lib.set_status(data, args.id, args.status)
    _save(data, args)
    print("%s -> %s" % (args.id, item["status"]))
    return 0


def cmd_comment(args):
    data = _load(args)
    comment = tasks_lib.add_comment(data, args.id, args.text, args.author)
    _save(data, args)
    print("Comment %d added to %s" % (comment["id"], args.id))
    return 0


def cmd_queue(args):
    data = _load(args)
    if args.queue_cmd == "list":
        for pos, tid in enumerate(data.get("queue") or [], 1):
            item = tasks_lib.find_task(data, tid)
            st = item.get("status") if item else "missing"
            title = item.get("title") if item else "(missing)"
            print("%2d  %s  [%s]  %s" % (pos, tid, st, title))
        return 0
    if args.queue_cmd == "add":
        changed = tasks_lib.queue_add(data, args.id)
        _save(data, args)
        pos = data["queue"].index(args.id) + 1
        print("%s at position %d" % ("Queued" if changed else "Already queued", pos))
        return 0
    if args.queue_cmd == "remove":
        changed = tasks_lib.queue_remove(data, args.id)
        _save(data, args)
        print("%s" % ("Unqueued" if changed else "Not in queue"))
        return 0
    return 1


def cmd_next(args):
    data = _load(args)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog=__doc__)
    parser.add_argument("--file", default=None, help="alternative TASKS.yaml path "
                     "(default: env AWECRAFT_TASKS_FILE or tasks/TASKS.yaml)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("add", help="add a new task")
    p.add_argument("--title", required=True)
    p.add_argument("--source", required=True, choices=tasks_lib.SOURCES)
    p.add_argument("--priority", type=int, default=2, choices=tasks_lib.PRIORITIES)
    p.add_argument("--notes", default="")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("status", help="change a task's status")
    p.add_argument("id")
    p.add_argument("status", choices=tasks_lib.STATUSES)
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("comment", help="add a comment to a task")
    p.add_argument("id")
    p.add_argument("text")
    p.add_argument("--author", choices=tasks_lib.SOURCES, default=None,
                   help="prefix the comment with [user]/[agent] (registry convention)")
    p.set_defaults(fn=cmd_comment)

    p = sub.add_parser("queue", help="work-order queue management")
    p.add_argument("queue_cmd", choices=["add", "remove", "list"])
    p.add_argument("id", nargs="?", default=None, help="task id (for add/remove)")
    p.set_defaults(fn=cmd_queue)

    p = sub.add_parser("next", help="print the next live queue item")
    p.set_defaults(fn=cmd_next)

    args = parser.parse_args()
    try:
        if args.cmd == "queue" and args.queue_cmd in ("add", "remove") and not args.id:
            print("queue %s requires <id>" % args.queue_cmd, file=sys.stderr)
            return 2
        return args.fn(args)
    except (NotFound, TaskError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
