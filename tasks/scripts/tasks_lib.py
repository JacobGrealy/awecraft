"""Shared library for the AweCraft task registry (tasks/TASKS.yaml).

Mirrors the user's work todo system (awe-jarvis todo-backup): one library owns
loading, saving and every mutation, and every caller (the CLI in tasks.py, the
webui in tasks/webui.py) goes through it. Rules that must not drift between
callers live here once:

  * status done  =>  completed_at is set; leaving done clears it
  * comment ids increment per task
  * every mutation bumps the task's updated_at AND top-level meta.updated_at

Mutations take and return the loaded dict and do NOT save; the caller persists
when the whole edit is done, so a multi-field change is one atomic write.

TASKS_DIR / TASKS_PATH are module-level and get repointed by `webui.py
--sandbox` and by the smoke test (env AWECRAFT_TASKS_FILE), the same trick
jarvis's todo_lib uses.
"""

import os
import re
from datetime import datetime
from pathlib import Path

import yaml

TASKS_DIR = Path(__file__).resolve().parent.parent
_ENV_FILE = os.environ.get("AWECRAFT_TASKS_FILE", "")
TASKS_PATH = Path(_ENV_FILE).expanduser().resolve() if _ENV_FILE else TASKS_DIR / "TASKS.yaml"

ID_RE = re.compile(r"^AC-(\d{4,})$")
STATUSES = ["open", "in-progress", "blocked", "done"]
SOURCES = ["user", "agent"]
PRIORITIES = (1, 2, 3)
TASK_SECTIONS = ("intake",)


class TaskError(Exception):
    """A rejected operation with a message fit to show the user."""


class NotFound(TaskError):
    """The target of an operation does not exist (maps to 404 in the webui).


    Subclasses TaskError so every `except TaskError` still catches it."""


def now_iso():
    """Current datetime, minute precision, matching the existing timestamps."""
    return datetime.now().strftime("%Y-%m-%dT%H:%M")


def load_tasks(path=None):
    """Load TASKS.yaml into a normalised dict (meta/queue/intake always present)."""
    p = Path(path) if path else TASKS_PATH
    with open(p) as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("meta", {})
    data.setdefault("queue", [])
    for section in TASK_SECTIONS:
        data[section] = data.get(section) or []
    return data


def save_tasks(data, path=None):
    """Write the registry back, preserving key order and readability."""
    p = Path(path) if path else TASKS_PATH
    with open(p, "w") as f:
        yaml.dump(
            data,
            f,
            default_flow_style=False,
            sort_keys=False,
            allow_unicode=True,
            width=120,
        )


def iter_tasks(data):
    """Yield every task dict found in any list-of-tasks value of the store.

    The registry currently keeps all tasks in `intake`, but deriving instead of
    hard-coding the section list means a future section can't go invisible.
    """
    for value in data.values():
        if not isinstance(value, list):
            continue
        for item in value:
            tid = item.get("id") if isinstance(item, dict) else None
            if isinstance(tid, str) and ID_RE.match(tid):
                yield item


def find_task(data, task_id):
    """Find a task by id (e.g. 'AC-0046') anywhere in the store, or None."""
    for item in iter_tasks(data):
        if item["id"] == task_id:
            return item
    return None


def next_id(data):
    """Next available task id: highest existing AC-NNNN plus one, zero-padded."""
    max_n = 0
    for item in iter_tasks(data):
        n = int(ID_RE.match(item["id"]).group(1))
        if n > max_n:
            max_n = n
    return "AC-%04d" % (max_n + 1)


def _bump_meta(data, now=None):
    """Top-level meta.updated_at moves whenever anything in the registry moves."""
    now = now or now_iso()
    data.setdefault("meta", {})["updated_at"] = now
    return now


def new_task(task_id, title, source, priority, notes=""):
    """A new task dict with the full registry schema in the canonical field order."""
    now = now_iso()
    return {
        "id": task_id,
        "title": title,
        "source": source,
        "projects": ["awecraft"],
        "assignee": "opencode",
        "priority": priority,
        "status": "open",
        "labels": [],
        "created_at": now,
        "updated_at": now,
        "completed_at": None,
        "waiting_on": None,
        "parent_id": None,
        "notes": notes,
        "comments": [],
    }


def add(data, title, source, priority=2, notes=""):
    """Append a new task to intake. Returns the created task dict."""
    title = (title or "").strip()
    if not title:
        raise TaskError("Title cannot be empty")
    if source not in SOURCES:
        raise TaskError("source must be one of %s, got %r" % (SOURCES, source))
    try:
        priority = int(priority)
    except (TypeError, ValueError):
        raise TaskError("priority must be 1-3, got %r" % (priority,))
    if priority not in PRIORITIES:
        raise TaskError("priority must be 1-3, got %r" % (priority,))
    item = new_task(next_id(data), title, source, priority, notes)
    data["intake"].append(item)
    _bump_meta(data, item["created_at"])
    return item


def set_status(data, task_id, status):
    """Set a task's status. done => completed_at set + auto-dequeue; leaving done => cleared."""
    status = str(status)
    if status not in STATUSES:
        raise TaskError("status must be one of %s, got %r" % (STATUSES, status))
    item = find_task(data, task_id)
    if item is None:
        raise NotFound("task %s not found" % task_id)
    now = now_iso()
    item["status"] = status
    if status == "done":
        if not item.get("completed_at"):
            item["completed_at"] = now
        # auto-dequeue: done items leave the work queue (was historical, now we prune)
        queue = data.get("queue") or []
        if task_id in queue:
            queue.remove(task_id)
    else:
        item["completed_at"] = None
    item["updated_at"] = now
    _bump_meta(data, now)
    return item


def add_comment(data, task_id, text, author=None):
    """Append a comment (id increments per task). Returns the comment dict.

    When `author` is given the text gets the registry's `[author] ` prefix,
    unless it already carries it, so hand-written and CLI/web comments stay in
    the same format as the existing threads.
    """
    text = (text or "").strip()
    if not text:
        raise TaskError("comment cannot be empty")
    if author is not None and author not in SOURCES:
        raise TaskError("author must be one of %s, got %r" % (SOURCES, author))
    item = find_task(data, task_id)
    if item is None:
        raise NotFound("task %s not found" % task_id)
    if author and not text.startswith("[%s]" % author):
        text = "[%s] %s" % (author, text)
    comments = item.setdefault("comments", [])
    comment = {
        "id": max([c.get("id", 0) for c in comments], default=0) + 1,
        "created_at": now_iso(),
        "updated_at": None,
        "text": text,
    }
    comments.append(comment)
    item["updated_at"] = comment["created_at"]
    _bump_meta(data, comment["created_at"])
    return comment


def queue_add(data, task_id):
    """Append a task to the end of the committed queue. No-op if already queued.

    Returns True if the queue changed."""
    if find_task(data, task_id) is None:
        raise NotFound("task %s not found" % task_id)
    queue = data.setdefault("queue", [])
    if task_id in queue:
        return False
    queue.append(task_id)
    _bump_meta(data)
    return True


def queue_remove(data, task_id):
    """Remove a task from the queue. No-op if it was not there."""
    queue = data.get("queue") or []
    if task_id not in queue:
        return False
    queue.remove(task_id)
    _bump_meta(data)
    return True


def queue_reorder(data, ordered_ids):
    """Replace the queue with `ordered_ids` after validating it is a permutation.

    Returns True if the queue changed. The caller must contain exactly the same
    set of ids as the current queue (no adds/removes, just reordering); this
    keeps the drag-handle from accidentally dropping or duplicating entries.
    """
    cur = list(data.get("queue") or [])
    ordered = list(ordered_ids or [])
    if set(ordered) != set(cur) or len(ordered) != len(cur):
        raise TaskError("queue reorder must be a permutation of the current queue")
    for tid in ordered:
        if find_task(data, tid) is None:
            raise NotFound("task %s not found" % tid)
    if ordered == cur:
        return False
    data["queue"] = ordered
    _bump_meta(data)
    return True


def queue_move(data, task_id, to_index):
    """Move `task_id` to `to_index` (0-based) inside the queue."""
    queue = list(data.get("queue") or [])
    if task_id not in queue:
        raise NotFound("task %s not in queue" % task_id)
    try:
        to_index = int(to_index)
    except (TypeError, ValueError):
        raise TaskError("to_index must be an integer")
    to_index = max(0, min(to_index, len(queue) - 1))
    cur = queue.index(task_id)
    if cur == to_index:
        return False
    queue.pop(cur)
    queue.insert(to_index, task_id)
    data["queue"] = queue
    _bump_meta(data)
    return True


def queue_top(data):
    """The next live item: first queue entry (queue now contains only live tasks)."""
    queue = data.get("queue") or []
    return queue[0] if queue else None
