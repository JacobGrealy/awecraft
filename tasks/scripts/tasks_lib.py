"""Shared library for the AweCraft task registry (tasks/TASKS.yaml).

Mirrors the user's work todo system (awe-jarvis todo-backup): one library owns
loading, saving and every mutation, and every caller (the CLI in tasks.py, the
webui in tasks/webui.py) goes through it. Rules that must not drift between
callers live here once:

  * status done  =>  completed_at is set; leaving done clears it
  * comment ids increment per task
  * every mutation bumps the task's updated_at AND top-level meta.updated_at
    (set_fields/appends that change nothing bump nothing: a no-op is a no-op)

TASKS_DIR / TASKS_PATH are module-level and get repointed by `webui.py
--sandbox` and by the smoke test (env AWECRAFT_TASKS_FILE), the same trick
jarvis's todo_lib uses.

Single-writer discipline (AC-0254): every byte that ever lands in TASKS.yaml
goes through exactly one code path. Writers:

  * CLI (tasks.py): `with registry_lock(path)` around the WHOLE
    read-modify-write, then commit_write().
  * webui (tasks/webui.py): save_tasks() (lock + dump + replace + validate).

Both paths:
  1. EXCLUSIVE LOCK: blocking fcntl.flock(LOCK_EX) on the sidecar file
     <registry dir>/.tasks.lock, released on exit.
  2. CANONICAL DUMP: yaml.safe_dump-equivalent (a SafeDumper subclass, since
     safe_dump() refuses a custom Dumper argument), sort_keys=False,
     width=100, allow_unicode=True, default_flow_style=False; canonical key
     order (canonical keys first, any other keys — comments, area, ... — in
     their original order); strings that would re-resolve to a non-str type
     when written plain (second-precision timestamps, numbers, bools, nulls)
     are always quoted so no str value can change type on reload.
  3. ATOMIC WRITE: temp file in the registry's own directory, fsync, then
     os.replace() over the registry. A reader (or a crash) can never observe
     a partial file.
  4. POST-WRITE VALIDATION: re-read the file after the replace and assert
     (a) the intended change is present and (b) every other entry — and the
     queue/meta for commands that do not touch them — is data-identical pre
     vs post (loaded dicts compared, not bytes). On any mismatch the
     original file bytes are restored and ValidationFailed is raised.

Determinism: dump(load(dump(x))) == dump(x), so once a file has been written
by the API, a no-op mutation rewrites it byte-identical.
"""

import contextlib
import fcntl
import os
import re
import stat
import tempfile
from datetime import datetime
from pathlib import Path

import yaml

TASKS_DIR = Path(__file__).resolve().parent.parent
_ENV_FILE = os.environ.get("AWECRAFT_TASKS_FILE", "")
TASKS_PATH = Path(_ENV_FILE).expanduser().resolve() if _ENV_FILE else TASKS_DIR / "TASKS.yaml"

ID_RE = re.compile(r"^AC-(\d{4,})$")
STATUSES = ["open", "in-progress", "blocked", "done", "cancelled"]
SOURCES = ["user", "agent"]
PRIORITIES = (1, 2, 3)
TASK_SECTIONS = ("intake",)

LOCK_BASENAME = ".tasks.lock"

# Canonical entry key order: these keys (when present) first, in this order;
# any other key the entry carries (comments, area, effort, ...) follows in
# its original order, so non-house schemas round-trip as data.
CANONICAL_ENTRY_KEYS = (
    "id", "title", "source", "projects", "assignee", "priority", "status",
    "labels", "created_at", "updated_at", "completed_at", "waiting_on",
    "parent_id", "notes",
)
CANONICAL_TOP_KEYS = ("meta", "queue", "intake")

_STR_TAG = "tag:yaml.org,2002:str"


class TaskError(Exception):
    """A rejected operation with a message fit to show the user."""


class NotFound(TaskError):
    """The target of an operation does not exist (maps to 404 in the webui).


    Subclasses TaskError so every `except TaskError` still catches it."""


class ValidationFailed(TaskError):
    """Post-write validation failed; the original file bytes were restored."""


# ---------------------------------------------------------------------------
# single-writer layer: lock, canonical dump, atomic write, post-write check
# ---------------------------------------------------------------------------

def _plain_tag(scalar):
    """The implicit tag YAML would assign to `scalar` if it were written plain.

    Mirrors yaml.resolver.Resolver.resolve(): implicit resolvers keyed by the
    first character, then the ''/None-keyed ones (empty string / specials).
    """
    first = scalar[0] if scalar else ""
    resolvers = yaml.resolver.Resolver.yaml_implicit_resolvers
    for tag, regexp in list(resolvers.get(first, [])) + list(resolvers.get(None, [])):
        if regexp.match(scalar):
            return tag
    return _STR_TAG


class _CanonicalDumper(yaml.SafeDumper):
    """SafeDumper plus one safety rule: a single-line string that would
    re-resolve to a non-string when written plain (second-precision
    timestamps, numbers, bools, null-ish words) is always single-quoted, so a
    str value can never silently become a datetime/int/bool on reload."""

    def represent_str(self, data):
        if data and "\n" not in data and _plain_tag(data) != _STR_TAG:
            return self.represent_scalar(_STR_TAG, data, style="'")
        return super().represent_str(data)


_DUMP_KWARGS = dict(sort_keys=False, width=100, allow_unicode=True,
                    default_flow_style=False)


def canonicalize_entry(entry):
    """Entry with canonical key order: canonical keys first (only the ones the
    entry actually has), then any other keys in their original order."""
    out = {}
    for key in CANONICAL_ENTRY_KEYS:
        if key in entry:
            out[key] = entry[key]
    for key, value in entry.items():
        if key not in out:
            out[key] = value
    return out


def canonicalize(data):
    """Top-level shape in canonical order (meta, queue, intake first, any
    other top-level keys after, in original order); intake entries canonical.
    Nothing is added, dropped or renamed."""
    out = {}
    for key in CANONICAL_TOP_KEYS:
        if key in data:
            out[key] = data[key]
    for key, value in data.items():
        if key not in out:
            out[key] = value
    if isinstance(out.get("intake"), list):
        out["intake"] = [canonicalize_entry(e) if isinstance(e, dict) else e
                         for e in out["intake"]]
    return out


def canonical_dump(data):
    """The registry's canonical text form.

    Deterministic: canonical_dump(load(canonical_dump(x))) ==
    canonical_dump(x), so once written by the API the file is byte-stable for
    unchanged data (idempotent no-op writes).
    """
    return yaml.dump(canonicalize(data), Dumper=_CanonicalDumper, **_DUMP_KWARGS)


def entry_dump(item):
    """Canonical text form of one entry (used by `show`)."""
    return yaml.dump(canonicalize_entry(item), Dumper=_CanonicalDumper, **_DUMP_KWARGS)


@contextlib.contextmanager
def registry_lock(path):
    """Exclusive blocking lock on the sidecar file next to the registry.

    fcntl.flock(LOCK_EX) on <registry dir>/.tasks.lock; waiting writers block
    until the lock frees (never skip, never time out), and it is released on
    exit of the with-block (fd close). The CLI holds it across the entire
    read-modify-write; save_tasks holds it around dump+replace+validate.
    """
    p = Path(path) if path else TASKS_PATH
    lock_path = p.parent / LOCK_BASENAME
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield lock_path
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def read_registry(path=None):
    """(original_bytes, parsed_dict) — the exact on-disk state, no defaults.

    The bytes are kept so commit_write can restore them verbatim if
    post-write validation fails."""
    p = Path(path) if path else TASKS_PATH
    try:
        with open(p, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        raise TaskError("registry file not found: %s" % p)
    try:
        data = yaml.safe_load(raw.decode("utf-8"))
    except (yaml.YAMLError, UnicodeDecodeError) as exc:
        raise TaskError("cannot parse %s: %s" % (p, exc))
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise TaskError("%s: top level must be a mapping" % p)
    return raw, data


def _atomic_write(path, text):
    """Write text to a temp file in path's directory, fsync it (and chmod it
    to the target's mode), then os.replace() over path and fsync the dir.
    os.replace is atomic on POSIX: readers never see a partial registry."""
    p = Path(path)
    try:
        mode = stat.S_IMODE(os.stat(p).st_mode)
    except OSError:
        mode = None
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".TASKS.yaml.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
            if mode is not None:
                os.fchmod(f.fileno(), mode)
        os.replace(tmp, str(p))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(str(p.parent), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def _restore(path, original_bytes):
    """Put the pre-write bytes back (plain write + fsync; still under lock)."""
    with open(path, "wb") as f:
        f.write(original_bytes)
        f.flush()
        os.fsync(f.fileno())


def _diff_issues(original, reloaded, changed_idx, added_id, queue_touched, meta_touched):
    """Data-identity issues between the pre-write state and the re-read file,
    comparing loaded dicts (not bytes): every entry not in changed_idx must be
    equal in place, no entry may be lost, no unexpected entry may appear, and
    queue/meta must be untouched unless the command declared it touched them."""
    issues = []
    oe = original.get("intake") or []
    ne = reloaded.get("intake") or []
    expected = len(oe) + (1 if added_id else 0)
    if len(ne) != expected:
        issues.append("entry count %d -> %d (expected %d)" % (len(oe), len(ne), expected))
    for i, (a, b) in enumerate(zip(oe, ne)):
        if i in changed_idx:
            a_id = a.get("id") if isinstance(a, dict) else repr(a)[:40]
            if not (isinstance(b, dict) and b.get("id") == a_id):
                issues.append("entry %s replaced by a different entry at index %d" % (a_id, i))
            continue
        if a != b:
            a_id = a.get("id") if isinstance(a, dict) else repr(a)[:40]
            issues.append("entry %s (index %d) changed unexpectedly" % (a_id, i))
    if added_id:
        tail = ne[len(oe):]
        if not any(isinstance(x, dict) and x.get("id") == added_id for x in tail):
            issues.append("new entry %s not present at the end of intake" % added_id)
    if not queue_touched and (original.get("queue") or []) != (reloaded.get("queue") or []):
        issues.append("queue changed unexpectedly")
    if not meta_touched and (original.get("meta") or {}) != (reloaded.get("meta") or {}):
        issues.append("meta changed unexpectedly")
    return issues


def commit_write(path, original_bytes, original, data, *,
                 changed_idx=(), added_id=None,
                 queue_touched=False, meta_touched=False,
                 intended=None):
    """The single-writer commit. Must be called while holding
    registry_lock(path).

    canonical_dump(data) -> atomic replace over the registry -> re-read the
    file -> validate: (a) `intended(reloaded)` (a callable that raises
    TaskError when the intended change is not visible) and (b) every other
    entry / queue / meta data-identical per _diff_issues. On ANY mismatch the
    original file bytes are restored and ValidationFailed is raised (the CLI
    exits non-zero). Returns a before/after summary dict.

    changed_idx: intake indices whose entry may differ (must keep its id).
    added_id: an entry expected to appear appended at the end of intake.
    """
    p = Path(path) if path else TASKS_PATH
    text = canonical_dump(data)
    _atomic_write(p, text)
    try:
        with open(p, "rb") as f:
            reloaded = yaml.safe_load(f.read().decode("utf-8"))
        if reloaded is None:
            reloaded = {}
        if not isinstance(reloaded, dict):
            raise yaml.YAMLError("top level is not a mapping")
    except (yaml.YAMLError, UnicodeDecodeError) as exc:
        _restore(p, original_bytes)
        raise ValidationFailed("post-write validation: %s does not parse after write "
                               "(%s); original file restored" % (p, exc))
    issues = []
    if intended is not None:
        try:
            intended(reloaded)
        except TaskError as exc:
            issues.append("intended change not visible: %s" % exc)
    issues.extend(_diff_issues(original, reloaded, set(changed_idx), added_id,
                               queue_touched, meta_touched))
    if issues:
        _restore(p, original_bytes)
        raise ValidationFailed("post-write validation failed, original file restored: "
                               + "; ".join(issues))
    oe = original.get("intake") or []
    ne = reloaded.get("intake") or []
    return {
        "entries_before": len(oe),
        "entries_after": len(ne),
        "queue_before": len(original.get("queue") or []),
        "queue_after": len(reloaded.get("queue") or []),
        "meta_before": dict(original.get("meta") or {}),
        "meta_after": dict(reloaded.get("meta") or {}),
    }


def save_tasks(data, path=None):
    """Simple single-writer save (the webui path): lock + canonical dump +
    atomic replace + validation that what was passed in is exactly what is on
    disk. Restores the previous bytes and raises ValidationFailed on any
    mismatch. The CLI uses registry_lock + commit_write for the stronger
    before/after checks."""
    p = Path(path) if path else TASKS_PATH
    with registry_lock(p):
        if p.exists():
            with open(p, "rb") as f:
                original_bytes = f.read()
        else:
            original_bytes = b""
        _atomic_write(p, canonical_dump(data))
        try:
            with open(p, "rb") as f:
                reloaded = yaml.safe_load(f.read().decode("utf-8"))
            if reloaded is None:
                reloaded = {}
            if not isinstance(reloaded, dict):
                raise yaml.YAMLError("top level is not a mapping")
        except (yaml.YAMLError, UnicodeDecodeError) as exc:
            _restore(p, original_bytes)
            raise ValidationFailed("post-write validation: %s does not parse after write "
                                   "(%s); original file restored" % (p, exc))
        if reloaded != data:
            _restore(p, original_bytes)
            raise ValidationFailed("post-write validation: data on disk differs from "
                                   "the data passed in; original file restored")
    return data


# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

def normalize(data):
    """Add the always-present top-level keys (meta/queue/intake) in place.

    load_tasks() = read the file + parse + normalize; read_registry() returns
    the raw state so writers can diff against exactly what was on disk."""
    data.setdefault("meta", {})
    data.setdefault("queue", [])
    for section in TASK_SECTIONS:
        data[section] = data.get(section) or []
    return data


def load_tasks(path=None):
    """Load TASKS.yaml into a normalised dict (meta/queue/intake always present)."""
    p = Path(path) if path else TASKS_PATH
    with open(p) as f:
        data = yaml.safe_load(f) or {}
    return normalize(data)


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


def now_iso():
    """Current datetime, minute precision, matching the existing timestamps."""
    return datetime.now().strftime("%Y-%m-%dT%H:%M")


# ---------------------------------------------------------------------------
# mutations (take and return the loaded dict; the caller persists — one
# multi-field edit is one locked atomic write)
# ---------------------------------------------------------------------------

def new_task(task_id, title, source, priority, notes="", status="open", labels=()):
    """A new task dict with the full registry schema in the canonical field order."""
    now = now_iso()
    return {
        "id": task_id,
        "title": title,
        "source": source,
        "projects": ["awecraft"],
        "assignee": "opencode",
        "priority": priority,
        "status": status,
        "labels": list(labels or []),
        "created_at": now,
        "updated_at": now,
        "completed_at": now if status in ("done", "cancelled") else None,
        "waiting_on": None,
        "parent_id": None,
        "notes": notes,
        "comments": [],
    }


def add(data, title, source, priority=2, notes="", task_id=None, status="open", labels=()):
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
    if status not in STATUSES:
        raise TaskError("status must be one of %s, got %r" % (STATUSES, status))
    labels = [s.strip() for s in (labels or []) if s and s.strip()]
    if task_id:
        if not ID_RE.match(task_id):
            raise TaskError("task id must look like AC-NNNN, got %r" % (task_id,))
        if find_task(data, task_id) is not None:
            raise TaskError("task %s already exists" % task_id)
    else:
        task_id = next_id(data)
    item = new_task(task_id, title, source, priority, notes, status=status, labels=labels)
    data["intake"].append(item)
    _bump_meta(data, item["created_at"])
    return item


def set_status(data, task_id, status):
    """Set a task's status. done/cancelled => completed_at set + auto-dequeue; leaving done/cancelled => cleared."""
    status = str(status)
    if status not in STATUSES:
        raise TaskError("status must be one of %s, got %r" % (STATUSES, status))
    item = find_task(data, task_id)
    if item is None:
        raise NotFound("task %s not found" % task_id)
    now = now_iso()
    item["status"] = status
    if status in ("done", "cancelled"):
        if not item.get("completed_at"):
            item["completed_at"] = now
        # auto-dequeue: done/cancelled items leave the work queue
        queue = data.get("queue") or []
        if task_id in queue:
            queue.remove(task_id)
    else:
        item["completed_at"] = None
    item["updated_at"] = now
    _bump_meta(data, now)
    return item


def set_fields(data, task_id, status=None, priority=None):
    """Set status and/or priority on a task (the `set` command).

    Timestamps are bumped only when a value actually changes, so
    `set --id X --priority 2` against a priority-2 task is a true data no-op
    (idempotent). done/cancelled also sets completed_at and dequeues; leaving
    them clears completed_at. Returns (item, changed)."""
    item = find_task(data, task_id)
    if item is None:
        raise NotFound("task %s not found" % task_id)
    changed = False
    if status is not None:
        status = str(status)
        if status not in STATUSES:
            raise TaskError("status must be one of %s, got %r" % (STATUSES, status))
        if item.get("status") != status:
            item["status"] = status
            changed = True
        if status in ("done", "cancelled"):
            if not item.get("completed_at"):
                item["completed_at"] = now_iso()
                changed = True
            queue = data.get("queue") or []
            if task_id in queue:
                queue.remove(task_id)
                changed = True
        else:
            if item.get("completed_at") is not None:
                item["completed_at"] = None
                changed = True
    if priority is not None:
        try:
            priority = int(priority)
        except (TypeError, ValueError):
            raise TaskError("priority must be 1-3, got %r" % (priority,))
        if priority not in PRIORITIES:
            raise TaskError("priority must be 1-3, got %r" % (priority,))
        if item.get("priority") != priority:
            item["priority"] = priority
            changed = True
    if changed:
        now = now_iso()
        item["updated_at"] = now
        _bump_meta(data, now)
    return item, changed


def append_notes(data, task_id, text):
    """Append text to the task's notes (the `note` command).

    Creates notes when absent; inserts a blank line before the appended text
    when notes exist. Bumps updated_at + meta. Returns the item."""
    text = (text or "").rstrip("\n")
    if not text:
        raise TaskError("no text to append")
    item = find_task(data, task_id)
    if item is None:
        raise NotFound("task %s not found" % task_id)
    current = item.get("notes")
    item["notes"] = (str(current) + "\n\n" + text) if current else text
    now = now_iso()
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


def queue_insert(data, task_id, at="end", anchor=None):
    """Place task_id in the queue: at head, at end, or after `anchor`.

    If it is already queued it is MOVED to the new position (queue_add keeps
    the legacy no-op-if-present behaviour). Returns (position, moved)."""
    if find_task(data, task_id) is None:
        raise NotFound("task %s not found" % task_id)
    if at not in ("head", "end", "after"):
        raise TaskError("queue position must be head, end, or after, got %r" % (at,))
    if at == "after" and not anchor:
        raise TaskError("queue 'after' requires an anchor id")
    queue = data.setdefault("queue", [])
    moved = task_id in queue
    if moved:
        queue.remove(task_id)
    if at == "head":
        queue.insert(0, task_id)
    elif at == "end":
        queue.append(task_id)
    else:
        if anchor not in queue:
            raise NotFound("anchor %s not in queue" % anchor)
        queue.insert(queue.index(anchor) + 1, task_id)
    _bump_meta(data)
    return queue.index(task_id) + 1, moved


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
