"""Render tasks/TASKS.yaml as a board HTML page.

Shared render layer (jarvis generate_view pattern): the CLI (`python3
tasks/scripts/render.py`) and the webui (`tasks/webui.py`) both call these
functions, so the human view and the live board can never disagree about layout.

Board layout:
  Queue (ordered line) -> Open (active work, by priority) -> Blocked -> Done
  Open/Blocked are full cards (id/title/status/priority/created/updated/notes
  + comment thread + links into the task folder); Done is a compact table
  (the registry accumulates many finished tasks, full cards would bury the rest).
  Links point at tasks/<id>/spec.html, <id>-results.html and any PNGs in the
  task folder, using `base` as the URL prefix ("" for a file saved next to
  tasks/, "/tasks/" for the webui which serves the static tasks/ dir).
"""

import argparse
import sys
from html import escape
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tasks_lib  # noqa: E402

STATUS_ORDER = {"in-progress": 0, "open": 1, "blocked": 2}

CSS = """
body{font-family:system-ui,'Segoe UI',sans-serif;margin:0;background:#f2f4f8;color:#1b232f}
.bar{background:#1f2733;color:#eef1f6;padding:10px 22px;display:flex;gap:14px;align-items:baseline;flex-wrap:wrap}
.bar h1{font-size:16px;margin:0;font-weight:600}
.bar .stamp{font-size:12px;opacity:.75}
.wrap{max-width:1080px;margin:0 auto;padding:18px 22px 60px}
.queue{background:#fff;border:1px solid #d7dee8;border-radius:6px;padding:10px 14px;margin-bottom:18px;font-size:13px}
.queue b{font-weight:600}
.qchip{display:inline-block;background:#eef1f6;border:1px solid #cdd6e3;border-radius:10px;
  padding:1px 9px;margin:2px 3px 2px 0;font-size:12px;font-family:ui-monospace,monospace}
.qchip.done{opacity:.45;text-decoration:line-through}
.qchip.live{background:#fff7e0;border-color:#e6c86e;font-weight:600}
section{margin-bottom:26px}
section h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:#5a6675;
  border-bottom:1px solid #cdd6e3;padding-bottom:4px;margin:0 0 10px}
.card{background:#fff;border:1px solid #d7dee8;border-left:4px solid #9aa7b8;
  border-radius:6px;padding:10px 14px;margin-bottom:10px}
.card.st-in-progress{border-left-color:#3b7cd8}
.card.st-open{border-left-color:#6a9955}
.card.st-blocked{border-left-color:#c05252}
.chead{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap}
.tid{font-family:ui-monospace,monospace;font-size:12px;color:#5a6675}
.ctitle{font-weight:600;font-size:14px}
.chip{font-size:11px;border-radius:9px;padding:1px 8px;border:1px solid #cdd6e3;background:#eef1f6}
.chip.pri{font-weight:700}
.chip.p1{background:#fbe3e3;border-color:#e08a8a;color:#8c2f2f}
.chip.p2{background:#fdf3dc;border-color:#e6c86e;color:#7a5b12}
.chip.p3{background:#e8effa;border-color:#9db8e0;color:#2f4d7a}
.chip.st{font-weight:600}
.cmeta{font-size:11px;color:#7a8494;margin-top:3px}
.notes{font-size:13px;margin-top:7px;white-space:pre-wrap}
.waiting{font-size:12px;color:#8c2f2f;background:#fbe3e3;border:1px solid #e08a8a;
  border-radius:5px;padding:4px 8px;margin-top:7px;display:inline-block}
.comments{margin-top:9px;border-top:1px dashed #d7dee8;padding-top:8px}
.comment{font-size:12px;margin-bottom:6px}
.comment .cm{color:#7a8494;font-size:11px;font-family:ui-monospace,monospace;margin-right:6px}
.links{margin-top:8px;font-size:12px}
.links a{color:#2f5fa8;text-decoration:none;margin-right:10px}
.links a:hover{text-decoration:underline}
table.done{width:100%;border-collapse:collapse;background:#fff;border:1px solid #d7dee8;border-radius:6px;font-size:12px}
details.dcard, details.card{cursor:default} summary.chead{list-style:none;display:flex;gap:8px;align-items:baseline;flex-wrap:wrap} summary.chead::-webkit-details-marker{display:none} summary.chead::before{content:'\25B8';color:#7a8494;font-size:11px} details[open].card summary.chead::before{content:'\25BE'} details.card.st-done{border-left-color:#b7c1cf}table.done th{background:#eef1f6;text-align:left;font-size:11px;text-transform:uppercase;
  letter-spacing:.05em;color:#5a6675;padding:7px 10px}
table.done td{padding:6px 10px;border-top:1px solid #e6ebf2}
table.done a{color:#2f5fa8;text-decoration:none}
.muted{color:#9aa7b8;font-style:italic;font-size:13px;padding:4px 2px}
form.newtask{background:#fff;border:1px solid #d7dee8;border-radius:6px;padding:10px 14px;margin-bottom:18px}
form.newtask label{font-size:11px;display:block;color:#5a6675;text-transform:uppercase;letter-spacing:.05em}
form.newtask input[type=text],form.newtask textarea{width:100%;box-sizing:border-box;
  border:1px solid #cdd6e3;border-radius:4px;padding:5px 7px;font:inherit;font-size:13px;margin-top:2px}
form.newtask .row{display:flex;gap:10px;margin-top:8px;align-items:flex-end;flex-wrap:wrap}
form.newtask select{border:1px solid #cdd6e3;border-radius:4px;padding:4px 6px;font:inherit;font-size:12px}
button{font:inherit;font-size:12px;border:1px solid #9db8e0;background:#3b7cd8;color:#fff;
  border-radius:4px;padding:4px 12px;cursor:pointer}
button:hover{background:#2f6ac0}
button.small{padding:1px 8px;font-size:11px;background:#fff;color:#2f5fa8}
.cform{margin-top:8px}
.cform textarea{width:100%;box-sizing:border-box;border:1px solid #cdd6e3;border-radius:4px;
  font:inherit;font-size:12px;padding:5px 7px;min-height:44px}
.cform .frow{display:flex;gap:8px;align-items:center;margin-top:4px}
.cform select{border:1px solid #cdd6e3;border-radius:4px;font-size:11px;padding:2px 4px}
select.stsel{border:1px solid #cdd6e3;border-radius:4px;font-size:11px;padding:1px 4px;background:#fff}
"""

PAGE_JS = """
document.addEventListener('submit', function (e) {
  var form = e.target.closest('form[data-act]');
  if (!form) return;
  e.preventDefault();
  postApi(form.dataset.act, new FormData(form));
});
document.addEventListener('change', function (e) {
  var sel = e.target.closest('select[data-act="status"]');
  if (!sel) return;
  postApi('status', new URLSearchParams({id: sel.dataset.id, status: sel.value}));
});
document.addEventListener('click', function (e) {
  var btn = e.target.closest('button[data-queue-act]');
  if (!btn) return;
  postApi(btn.dataset.queueAct, new URLSearchParams({id: btn.dataset.id}));
});
async function postApi(act, body) {
  var res = await fetch('/api/' + act, {method: 'POST', body: body});
  var data = {};
  try { data = await res.json(); } catch (err) { data = {ok: false, error: 'bad response'}; }
  if (!res.ok || !data.ok) { alert(data.error || ('request failed: ' + res.status)); return; }
  var board = document.getElementById('board');
  if (board && data.board) { board.innerHTML = data.board; }
}
"""


def _chip(text, cls=""):
    return '<span class="chip %s">%s</span>' % (cls, escape(text))


def _task_links_html(task_id, task_root, base):
    """Links into the task folder: spec.html, <id>-results.html, any PNGs."""
    if task_root is None:
        return ""
    folder = Path(task_root) / task_id
    if not folder.is_dir():
        return ""
    links = []
    spec = folder / "spec.html"
    if spec.is_file():
        links.append((base + task_id + "/spec.html", "spec"))
    results = folder / (task_id + "-results.html")
    if results.is_file():
        links.append((base + task_id + "/" + quote(task_id + "-results.html"), task_id + "-results.html"))
    for png in sorted(folder.glob("*.png")):
        links.append((base + task_id + "/" + quote(png.name), png.name))
    if not links:
        return ""
    items = "".join('<a href="%s">%s</a>' % (url, escape(label)) for url, label in links)
    return '<div class="links">%s</div>' % items


def _comments_html(item, interactive):
    rows = []
    for c in item.get("comments") or []:
        meta = '%s &middot; %s' % (escape(str(c.get("id", ""))), escape(str(c.get("created_at", ""))))
        rows.append('<div class="comment"><span class="cm">%s</span><span>%s</span></div>'
                    % (meta, escape(str(c.get("text", "")))))
    body = "".join(rows) if rows else '<div class="muted">no comments</div>'
    if interactive:
        author = item.get("source") or "agent"
        body += ('<form class="cform" data-act="comment">'
                 '<input type="hidden" name="id" value="%s">'
                 '<textarea name="text" placeholder="add a comment..." required></textarea>'
                 '<div class="frow"><label>author</label>'
                 '<select name="author"><option value="user" %s>user</option>'
                 '<option value="agent" %s>agent</option></select>'
                 '<button type="submit">add</button></div></form>'
                 % (escape(item["id"]),
                    "selected" if author == "user" else "",
                    "selected" if author == "agent" else ""))
    return '<div class="comments">%s</div>' % body


def _card_inner(item, interactive, base, task_root, queue):
    st = item.get("status") or "open"
    parts = []
    head = ['<span class="tid">%s</span>' % escape(item["id"]),
            '<span class="ctitle">%s</span>' % escape(str(item.get("title", "")))]
    pri = item.get("priority")
    if pri:
        head.append(_chip("P%s" % pri, "pri p%s" % pri))
    label = st.replace("-", " ")
    head.append(_chip(label, "st"))
    if interactive:
        opts = "".join(
            '<option value="%s"%s>%s</option>'
            % (s, " selected" if s == st else "", s.replace("-", " "))
            for s in tasks_lib.STATUSES)
        head.append('<select class="stsel" data-act="status" data-id="%s" title="set status">%s</select>'
                    % (escape(item["id"]), opts))
        if item["id"] in (queue or []):
            head.append('<button type="button" class="small" data-queue-act="queue_remove" '
                        'data-id="%s">dequeue</button>' % escape(item["id"]))
        else:
            head.append('<button type="button" class="small" data-queue-act="queue_add" '
                        'data-id="%s">queue</button>' % escape(item["id"]))
    parts.append('<div class="chead">%s</div>' % "".join(head))
    meta = []
    if item.get("source"):
        meta.append("source %s" % item["source"])
    meta.append("created %s" % item.get("created_at", "?"))
    meta.append("updated %s" % item.get("updated_at", "?"))
    if item.get("completed_at"):
        meta.append("done %s" % item["completed_at"])
    if item.get("labels"):
        meta.append("labels: " + ", ".join(item["labels"]))
    parts.append('<div class="cmeta">%s</div>' % "&middot;".join(escape(m) for m in meta))
    if item.get("waiting_on"):
        parts.append('<div class="waiting">waiting on: %s</div>' % escape(str(item["waiting_on"])))
    if item.get("notes"):
        parts.append('<div class="notes">%s</div>' % escape(str(item["notes"])))
    parts.append(_comments_html(item, interactive))
    parts.append(_task_links_html(item["id"], task_root, base))
    return "".join(parts)


def _card_html(item, interactive, base, task_root, queue):
    """Open/Blocked card: full detail, always visible."""
    st = item.get("status") or "open"
    return ('<div class="card st-%s" data-id="%s">%s</div>'
            % (escape(st), escape(item["id"]),
               _card_inner(item, interactive, base, task_root, queue)))


def _done_card_html(item, interactive, base, task_root, queue, open_detail):
    """Done card: same fields, in a details element so the history stays
    collapsible (first few open by default)."""
    st = item.get("status") or "done"
    summary = ('<span class="tid">%s</span> <span class="ctitle">%s</span> %s %s'
               % (escape(item["id"]),
                  escape(str(item.get("title", ""))),
                  ('<span class="chip pri p%s">%s</span>'
                   % (item["priority"], "P%s" % item["priority"])) if item.get("priority") else "",
                  ('<span class="cmeta">completed %s</span>' % escape(str(item.get("completed_at") or "?")))
                  if item.get("completed_at") else ""))
    return ('<details class="card st-done" data-id="%s"%s>'
            '<summary class="chead">%s</summary>%s</details>'
            % (escape(item["id"]), " open" if open_detail else "", summary,
               _card_inner(item, interactive, base, task_root, queue)))


def _queue_line(queue, data):
    top = tasks_lib.queue_top(data)
    chips = []
    for pos, tid in enumerate(queue, 1):
        item = tasks_lib.find_task(data, tid)
        st = (item or {}).get("status")
        cls = "qchip done" if st == "done" else ("qchip live" if tid == top else "qchip")
        chips.append('<span class="%s">%d&middot;%s</span>' % (cls, pos, escape(tid)))
    return ('<div class="queue"><b>Queue</b> &nbsp;' +
            ("".join(chips) if chips else '<span class="muted">empty</span>') + "</div>")


def _new_task_form():
    return ('<form class="newtask" data-act="add">'
            '<label>new task</label>'
            '<input type="text" name="title" placeholder="title (required)">'
            '<div class="row">'
            '<div><label>source</label><select name="source">'
            '<option value="user">user</option><option value="agent" selected>agent</option>'
            '</select></div>'
            '<div><label>priority</label><select name="priority">'
            '<option value="1">1 (highest)</option><option value="2" selected>2</option>'
            '<option value="3">3</option></select></div>'
            '<div style="flex:1;min-width:220px"><label>notes</label>'
            '<textarea name="notes" style="min-height:30px"></textarea></div>'
            '<button type="submit">add</button>'
            "</div></form>")


def build_board(data, interactive=True, base="/tasks/", task_root=None):
    """The board fragment: queue line, then Queue/Open/Blocked/Done sections."""
    data = tasks_lib.load_tasks() if data is None else data
    queue = list(data.get("queue") or [])
    items = list(tasks_lib.iter_tasks(data))
    open_items = [i for i in items if i.get("status") in ("open", "in-progress")]
    blocked_items = [i for i in items if i.get("status") == "blocked"]
    done_items = [i for i in items if i.get("status") == "done"]

    open_key = lambda i: (0 if i.get("status") == "in-progress" else 1,
                          i.get("priority") or 9, str(i["id"]))
    open_items.sort(key=open_key)
    blocked_items.sort(key=lambda i: (i.get("priority") or 9, str(i["id"])))
    done_items.sort(key=lambda i: (str(i.get("completed_at") or ""), str(i["id"])), reverse=True)

    out = [_queue_line(queue, data)]
    if interactive:
        out.append(_new_task_form())

    out.append('<section><h2>Queue (work order)</h2>')
    qrows = []
    for pos, tid in enumerate(queue, 1):
        item = tasks_lib.find_task(data, tid)
        title = item.get("title", "?") if item else "(missing)"
        st = (item or {}).get("status", "missing")
        qrows.append("<tr><td>%d</td><td><code>%s</code></td><td>%s</td><td>%s</td></tr>"
                     % (pos, escape(tid), escape(st), escape(title)))
    if qrows:
        out.append('<table class="done"><tr><th>#</th><th>id</th><th>status</th><th>title</th></tr>'
                   + "".join(qrows) + "</table>")
    else:
        out.append('<div class="muted">queue is empty</div>')
    out.append("</section>")

    out.append('<section><h2>Open (%d)</h2>' % len(open_items))
    if open_items:
        out.extend(_card_html(i, interactive, base, task_root, queue) for i in open_items)
    else:
        out.append('<div class="muted">nothing open</div>')
    out.append("</section>")

    out.append('<section><h2>Blocked (%d)</h2>' % len(blocked_items))
    if blocked_items:
        out.extend(_card_html(i, interactive, base, task_root, queue) for i in blocked_items)
    else:
        out.append('<div class="muted">nothing blocked</div>')
    out.append("</section>")

    out.append('<section><h2>Done (%d)</h2>' % len(done_items))
    if done_items:
        for n, i in enumerate(done_items):
            out.append(_done_card_html(i, interactive, base, task_root, queue, n < 3))
    else:
        out.append('<div class="muted">nothing done yet</div>')
    out.append("</section>")
    return "".join(out)


def render_page(data, interactive=True, base="/tasks/", task_root=None, title="AweCraft Tasks"):
    """Full HTML page (webui uses interactive=True; the CLI prints non-interactive)."""
    data = tasks_lib.load_tasks() if data is None else data
    body_css = CSS
    js = ("<script>%s</script>" % PAGE_JS) if interactive else ""
    meta = (data.get("meta") or {}).get("updated_at", "?")
    return ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            "<title>%s</title><style>%s</style>%s</head><body>"
            "<div class='bar'><h1>%s</h1>"
            "<span class='stamp'>registry updated %s</span></div>"
            "<div class='wrap' id='board'>%s</div>"
            "</body></html>"
            % (escape(title), body_css, js, escape(title), escape(str(meta)),
               build_board(data, interactive=interactive, base=base, task_root=task_root)))


def main():
    p = argparse.ArgumentParser(description="Render TASKS.yaml as a board HTML page")
    p.add_argument("--out", default=None, help="write the page here (default: print to stdout)")
    p.add_argument("--file", default=None, help="alternative TASKS.yaml path (default: env "
                   "AWECRAFT_TASKS_FILE or tasks/TASKS.yaml)")
    p.add_argument("--base", default="", help="URL prefix for task-folder links "
                   "('', /tasks/ for the webui)")
    args = p.parse_args()

    path = Path(args.file).expanduser().resolve() if args.file else tasks_lib.TASKS_PATH
    data = tasks_lib.load_tasks(path)
    task_root = path.parent if args.file else tasks_lib.TASKS_DIR
    html = render_page(data, interactive=False, base=args.base, task_root=task_root)
    if args.out:
        Path(args.out).write_text(html)
        print("wrote %s" % args.out)
    else:
        print(html)


if __name__ == "__main__":
    main()
