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
tr[draggable=true]{cursor:grab}
tr.dragging{opacity:.45}
tr.drag-over{outline:2px dashed #3b7cd8}
td.handle{cursor:grab;text-align:center;user-select:none;color:#7a8494;width:22px}
tr.task-row{cursor:pointer}
tr.task-row:hover{background:#eef1f6}
#modal{position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:rgba(16,22,32,.56);z-index:9999;padding:18px}
#modal.open{display:flex}
#modal .box{background:#fff;border-radius:8px;max-width:980px;width:100%;max-height:90vh;overflow:auto;border:1px solid #cdd6e3;box-shadow:0 12px 40px rgba(0,0,0,.25)}
#modal .boxhead{position:sticky;top:0;background:#fff;border-bottom:1px solid #e6ebf2;padding:10px 14px;display:flex;justify-content:space-between;align-items:center;gap:10px}
#modal .boxbody{padding:14px}
#modal .gallery{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
#modal .gallery img{max-width:220px;max-height:160px;border:1px solid #d7dee8;border-radius:4px;background:#fff}
#modal .results-frame{border:1px solid #d7dee8;border-radius:6px;padding:10px;background:#fbfcfe;margin-top:10px;max-height:60vh;overflow:auto}
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
  e.stopPropagation();
  postApi('status', new URLSearchParams({id: sel.dataset.id, status: sel.value}));
});
document.addEventListener('click', function (e) {
  var btn = e.target.closest('button[data-queue-act]');
  if (btn) { e.stopPropagation(); postApi(btn.dataset.queueAct, new URLSearchParams({id: btn.dataset.id})); return; }
  var sel = e.target.closest('select[data-act]');
  if (sel) return;
  var tr = e.target.closest('tr.task-row[data-tid]');
  if (tr) { openTaskModal(tr.dataset.tid); return; }
  if (e.target.closest('#modal')) {
    if (e.target.id==='modal' || e.target.closest('[data-close-modal]')) closeTaskModal();
  }
});
document.addEventListener('keydown', function(e){ if(e.key==='Escape') closeTaskModal(); });
(function(){
  var dragId=null;
  document.addEventListener('dragstart', function(e){
    var tr=e.target.closest('tr[data-qid]');
    if(!tr) return;
    dragId=tr.dataset.qid;
    e.dataTransfer.effectAllowed='move';
    e.dataTransfer.setData('text/plain', dragId);
    tr.classList.add('dragging');
  });
  document.addEventListener('dragend', function(e){
    var tr=e.target.closest('tr[data-qid]');
    if(tr) tr.classList.remove('dragging');
    document.querySelectorAll('tr.drag-over').forEach(function(r){r.classList.remove('drag-over')});
  });
  document.addEventListener('dragover', function(e){
    var tr=e.target.closest('tr[data-qid]');
    if(!tr) return;
    e.preventDefault();
    tr.classList.add('drag-over');
  });
  document.addEventListener('dragleave', function(e){
    var tr=e.target.closest('tr[data-qid]');
    if(tr) tr.classList.remove('drag-over');
  });
  document.addEventListener('drop', function(e){
    var tr=e.target.closest('tr[data-qid]');
    if(!tr || !dragId) return;
    if(!tr.closest('#queue-table')) return;
    e.preventDefault();
    tr.classList.remove('drag-over');
    var tbl=document.getElementById('queue-table');
    if(!tbl) return;
    var rows=[].slice.call(tbl.querySelectorAll('tr[data-qid]'));
    var src=rows.find(function(r){return r.dataset.qid===dragId});
    var dst=tr;
    if(!src || !dst || src===dst) return;
    var ids=rows.map(function(r){return r.dataset.qid});
    var sidx=ids.indexOf(dragId);
    var didx=ids.indexOf(dst.dataset.qid);
    ids.splice(sidx,1);
    ids.splice(didx,0,dragId);
    postApi('queue-reorder', new URLSearchParams({order: ids.join(',')}));
    dragId=null;
  });
})();
async function postApi(act, body) {
  var enc = body instanceof FormData ? new URLSearchParams(body) : body;
  var res = await fetch('/api/' + act, {method: 'POST', body: enc});
  var data = {};
  try { data = await res.json(); } catch (err) { data = {ok: false, error: 'bad response'}; }
  if (!res.ok || !data.ok) { alert(data.error || ('request failed: ' + res.status)); return; }
  var board = document.getElementById('board');
  if (board && data.board) { board.innerHTML = data.board; }
}
async function openTaskModal(tid){
  var m=document.getElementById('modal');
  var body=m.querySelector('.boxbody');
  m.classList.add('open');
  body.innerHTML='<div class="muted">loading '+tid+'...</div>';
  try{
    var res=await fetch('/api/task?id='+encodeURIComponent(tid));
    var data=await res.json();
    if(!res.ok || !data.ok) throw new Error(data.error||'failed');
    document.getElementById('modal-title').textContent=tid+' — '+data.task.title;
    body.innerHTML=data.modal;
  }catch(err){ body.innerHTML='<div class="waiting">failed: '+err.message+'</div>'; }
}
function closeTaskModal(){ var m=document.getElementById('modal'); if(m) m.classList.remove('open'); }
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


def _row_table(rows, table_id, show_handle=False, draggable=False, interactive=True):
    """Helper for one-row-per-task tables (queue/backlog/completed)."""
    if not rows:
        return '<div class="muted">none</div>'
    hdr_handle = '<th></th>' if (interactive and show_handle) else ''
    head = '<tr>%s<th>#</th><th>id</th><th>status</th><th>title</th><th>artifacts</th></tr>' % hdr_handle
    return '<table class="done" id="%s">%s%s</table>' % (table_id, head, "".join(rows))

def _modal_html(item, task_root, base, queue):
    """Full task detail for the modal: description, comments, results html, gallery."""
    tid = item["id"]
    # reuse card inner for description/meta/comments (without queue buttons duplication)
    inner = _card_inner(item, True, base, task_root, queue)
    # gallery + rendered results
    gallery = ""
    results_frame = ""
    if task_root is not None:
        folder = Path(task_root) / tid
        if folder.is_dir():
            imgs = sorted(folder.glob("*.png")) + sorted(folder.glob("*.jpg")) + sorted(folder.glob("*.jpeg"))
            if imgs:
                gallery = '<div class="gallery">' + "".join(
                    '<a href="%s" target="_blank"><img src="%s" alt="%s"></a>' % (base + tid + "/" + quote(p.name), base + tid + "/" + quote(p.name), escape(p.name))
                    for p in imgs) + '</div>'
            results = folder / (tid + "-results.html")
            if results.is_file():
                try:
                    html = results.read_text(encoding="utf-8", errors="replace")
                    # inline: if it's a full html doc, embed as-is inside a frame
                    results_frame = '<div class="results-frame">%s</div>' % html
                except Exception:
                    results_frame = '<div class="muted">results.html unreadable</div>'
            spec = folder / "spec.html"
            if spec.is_file():
                results_frame = '<div style="margin-bottom:8px"><a href="%s" target="_blank">spec.html</a></div>' % (base + tid + "/spec.html") + results_frame
    return inner + gallery + results_frame


def build_board(data, interactive=True, base="/tasks/", task_root=None):
    """Board: queue (draggable) + backlog (non-queued, not done) + completed (done) — all one-row tables. Detail is in the modal."""
    data = tasks_lib.load_tasks() if data is None else data
    queue = list(data.get("queue") or [])
    items = list(tasks_lib.iter_tasks(data))
    queued_set = set(queue)
    done_items = [i for i in items if i.get("status") == "done"]
    backlog_items = [i for i in items if i.get("status") != "done" and i["id"] not in queued_set]

    # sort backlog like before: in-progress first, then priority, then id
    backlog_items.sort(key=lambda i: (0 if i.get("status") == "in-progress" else 1, 1 if i.get("status") == "blocked" else 0, i.get("priority") or 9, str(i["id"])))
    done_items.sort(key=lambda i: (str(i.get("completed_at") or ""), str(i["id"])), reverse=True)

    out = [_queue_line(queue, data)]
    if interactive:
        out.append(_new_task_form())

    def _qrow(pos, tid, st, title, links_html, draggable, clickable_tid=None):
        drag = ' draggable="true"' if (interactive and draggable) else ''
        handle = '<td class="handle" title="drag to reorder">\u2630</td>' if (interactive and draggable) else ('<td class="handle" style="opacity:.25">\u2630</td>' if interactive and show_handle else '<td></td>')
        # clickable row — modal on click, drag handle still works; status changes stop propagation
        click_tid = clickable_tid or tid
        return ('<tr class="task-row" data-tid="%s" data-qid="%s"%s>%s<td>%d</td><td><code>%s</code></td><td>%s</td><td>%s</td><td style="font-size:11px">%s</td></tr>'
                % (escape(click_tid), escape(tid), drag, handle, pos, escape(tid), escape(st), escape(title), links_html))

    def _links_cell(tid):
        links = _task_links_html(tid, task_root, base)
        if links:
            return links.replace('<div class="links">', '').replace('</div>', '')
        return '<span class="muted">no artifacts</span>'

    # Queue — draggable, one-row, click opens modal
    show_handle = interactive
    out.append('<section><h2>Queue (%d)</h2>' % len(queue))
    if not queue:
        out.append('<div class="muted">queue is empty</div>')
    else:
        qrows = [_qrow(pos, tid, (tasks_lib.find_task(data, tid) or {}).get("status", "missing"),
                       (tasks_lib.find_task(data, tid) or {}).get("title", "?") if tasks_lib.find_task(data, tid) else "(missing)",
                       _links_cell(tid), True, tid)
                 for pos, tid in enumerate(queue, 1)]
        out.append(_row_table(qrows, "queue-table", show_handle=True, draggable=True, interactive=interactive))
        if interactive:
            out.append('<div class="muted" style="margin-top:4px">drag by \u2630 to reorder — click a row for details</div>')
    out.append("</section>")

    # Backlog — non-queued, not done
    out.append('<section><h2>Backlog (%d)</h2>' % len(backlog_items))
    if not backlog_items:
        out.append('<div class="muted">nothing in backlog</div>')
    else:
        brows = []
        for pos, it in enumerate(backlog_items, 1):
            tid = it["id"]
            st = it.get("status", "missing")
            title = it.get("title", "?")
            brows.append('<tr class="task-row" data-tid="%s"><td>%d</td><td><code>%s</code></td><td>%s</td><td>%s</td><td style="font-size:11px">%s</td></tr>'
                         % (escape(tid), pos, escape(tid), escape(st), escape(title), _links_cell(tid)))
        out.append(_row_table(brows, "backlog-table", show_handle=False, draggable=False, interactive=interactive))
        if interactive:
            out.append('<div class="muted" style="margin-top:4px">click a row for details — use queue button in modal to add to queue</div>')
    out.append("</section>")

    # Completed — done
    out.append('<section><h2>Completed (%d)</h2>' % len(done_items))
    if not done_items:
        out.append('<div class="muted">nothing completed yet</div>')
    else:
        crows = []
        for pos, it in enumerate(done_items, 1):
            tid = it["id"]
            st = it.get("status", "done")
            title = it.get("title", "?")
            crows.append('<tr class="task-row" data-tid="%s"><td>%d</td><td><code>%s</code></td><td>%s</td><td>%s</td><td style="font-size:11px">%s</td></tr>'
                         % (escape(tid), pos, escape(tid), escape(st), escape(title), _links_cell(tid)))
        out.append(_row_table(crows, "completed-table", show_handle=False, draggable=False, interactive=interactive))
        if interactive:
            out.append('<div class="muted" style="margin-top:4px">click a row for details</div>')
    out.append("</section>")
    return "".join(out)


def render_page(data, interactive=True, base="/tasks/", task_root=None, title="AweCraft Tasks"):
    """Full HTML page (webui uses interactive=True; the CLI prints non-interactive)."""
    data = tasks_lib.load_tasks() if data is None else data
    body_css = CSS
    js = ("<script>%s</script>" % PAGE_JS) if interactive else ""
    meta = (data.get("meta") or {}).get("updated_at", "?")
    modal = ('<div id="modal"><div class="box"><div class="boxhead"><span id="modal-title"></span>'
             '<button type="button" data-close-modal style="background:#fff;color:#1b232f;border:1px solid #cdd6e3">close</button></div>'
             '<div class="boxbody"></div></div></div>') if interactive else ""
    return ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            "<title>%s</title><style>%s</style>%s</head><body>"
            "<div class='bar'><h1>%s</h1>"
            "<span class='stamp'>registry updated %s</span></div>"
            "<div class='wrap' id='board'>%s</div>%s"
            "</body></html>"
            % (escape(title), body_css, js, escape(title), escape(str(meta)),
               build_board(data, interactive=interactive, base=base, task_root=task_root), modal))


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
