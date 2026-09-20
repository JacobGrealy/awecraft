// AC-0090 — the demo UI: plain DOM, no framework, no build step.
//
// Every control here is also reachable through window.__AC0090.set(), so the
// verification harness drives the page the same way a person does and the page
// does not need a test-only code path.

const CSS = `
.ac-panel{position:fixed;top:10px;left:10px;width:266px;max-height:calc(100% - 20px);overflow:auto;
  background:rgba(12,18,26,.88);border:1px solid #2b3a4b;border-radius:10px;color:#dce7f2;
  font:12px/1.45 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;padding:10px 12px 12px;
  backdrop-filter:blur(6px);z-index:10}
.ac-panel h1{font-size:13px;margin:0 0 2px;letter-spacing:.04em}
.ac-panel .sub{color:#7d90a4;font-size:11px;margin-bottom:8px}
.ac-sec{border-top:1px solid #22303f;margin-top:8px;padding-top:7px}
.ac-sec>b{display:block;color:#8fa6bd;font-size:10px;letter-spacing:.09em;text-transform:uppercase;margin-bottom:5px}
.ac-row{display:flex;gap:5px;flex-wrap:wrap;align-items:center;margin:3px 0}
.ac-row label{flex:0 0 auto;color:#a9bccd}
.ac-btn{background:#1b2735;border:1px solid #33475c;color:#cfe0f0;border-radius:6px;padding:3px 8px;
  font:11px ui-sans-serif,system-ui,sans-serif;cursor:pointer}
.ac-btn:hover{background:#243447}
.ac-btn.on{background:#2f6f57;border-color:#49a17c;color:#eafff5}
.ac-btn.wide{flex:1 1 auto;text-align:center}
.ac-range{flex:1 1 auto;min-width:90px}
input[type=range]{width:100%;accent-color:#49a17c}
.ac-stats{position:fixed;top:10px;right:10px;background:rgba(12,18,26,.88);border:1px solid #2b3a4b;
  border-radius:10px;color:#cfe0f0;font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;
  padding:8px 10px;z-index:10;min-width:246px;white-space:pre}
.ac-stats b{color:#7d90a4;font-weight:400}
.ac-hint{position:fixed;left:50%;bottom:8px;transform:translateX(-50%);color:#7d90a4;
  font:11px ui-sans-serif,system-ui,sans-serif;z-index:10;pointer-events:none;text-align:center}
.ac-panel.min .ac-body{display:none}
`;

export function buildUI(hooks) {
  const style = document.createElement('style');
  style.textContent = CSS;
  document.head.appendChild(style);

  const state = hooks.state;
  const chars = hooks.characters;

  const panel = document.createElement('div');
  panel.className = 'ac-panel';
  panel.innerHTML = `
    <h1>AC-0090 · primitive ragdoll characters</h1>
    <div class="sub">procedural body → seam-blended skin → toon → procedural gait</div>
    <div class="ac-body">
      <div class="ac-sec"><b>Quality tier</b>
        <div class="ac-row" id="tiers"></div>
        <div class="sub" id="tierNote" style="margin:4px 0 0"></div>
      </div>
      <div class="ac-sec"><b>Character</b>
        <div class="ac-row" id="chars"></div>
        <div class="ac-row"><button class="ac-btn wide" data-act="all">Frame all</button>
        <button class="ac-btn" data-act="tour">Auto-tour</button></div>
      </div>
      <div class="ac-sec"><b>Locomotion</b>
        <div class="ac-row"><label style="flex:0 0 42px">speed</label>
          <input class="ac-range" id="speed" type="range" min="0" max="2" step="0.01" value="1"></div>
        <div class="ac-row"><button class="ac-btn on" data-act="moveall">Walk all five</button></div>
      </div>
      <div class="ac-sec"><b>Shading</b>
        <div class="ac-row"><label style="flex:0 0 42px">bands</label>
          <input class="ac-range" id="bands" type="range" min="2" max="6" step="1" value="3"></div>
        <div class="ac-row">
          <button class="ac-btn on" data-tgl="toon">toon</button>
          <button class="ac-btn on" data-tgl="outline">outline</button>
        </div>
      </div>
      <div class="ac-sec"><b>Debug / A-B</b>
        <div class="ac-row">
          <button class="ac-btn" data-tgl="partDebug">per-primitive</button>
          <button class="ac-btn" data-tgl="seamDebug">blend windows</button>
        </div>
        <div class="ac-row">
          <button class="ac-btn" data-tgl="wire">wireframe</button>
          <button class="ac-btn" data-tgl="joints">joints</button>
        </div>
        <div class="sub" style="margin:4px 0 0">per-primitive / blend-window isolate the seam work;
          the tier row shows the three approaches side by side.</div>
      </div>
      <div class="ac-sec"><b>Generate</b>
        <div class="ac-row"><label style="flex:0 0 42px">seed</label>
          <input class="ac-range" id="seed" type="range" min="1" max="40" step="1" value="1"></div>
        <div class="ac-row"><button class="ac-btn wide" data-act="regen">Regenerate from seed</button></div>
      </div>
    </div>
  `;
  document.body.appendChild(panel);

  const stats = document.createElement('div');
  stats.className = 'ac-stats';
  document.body.appendChild(stats);

  const hint = document.createElement('div');
  hint.className = 'ac-hint';
  hint.textContent = 'drag to orbit · wheel to zoom · shift-drag to pan';
  document.body.appendChild(hint);

  // ---- tiers
  const tierBox = panel.querySelector('#tiers');
  const tierNote = panel.querySelector('#tierNote');
  const TIER_NOTE = {
    smooth: 'tube envelopes + baked bone blend (mobile default)',
    hard: 'the raw primitives, hard normals — the "before" arm',
    remesh: 'metaball union polygonised — one surface, no seams left',
  };
  hooks.TIERS.forEach((t) => {
    const b = document.createElement('button');
    b.className = 'ac-btn' + (t === state.tier ? ' on' : '');
    b.textContent = t;
    b.dataset.tier = t;
    b.onclick = () => {
      hooks.onTier(t);
      [...tierBox.children].forEach((x) => x.classList.toggle('on', x.dataset.tier === t));
      tierNote.textContent = TIER_NOTE[t];
      refreshStats();
    };
    tierBox.appendChild(b);
  });
  tierNote.textContent = TIER_NOTE[state.tier];

  // ---- characters
  const charBox = panel.querySelector('#chars');
  function buildCharButtons(list) {
    charBox.innerHTML = '';
    list.forEach((c) => {
      const b = document.createElement('button');
      b.className = 'ac-btn';
      b.textContent = c.preset;
      b.dataset.char = c.preset;
      b.onclick = () => {
        hooks.onFocus(c.preset);
        setFocus(c.preset);
      };
      charBox.appendChild(b);
    });
  }
  buildCharButtons(chars);

  function setFocus(name) {
    state.focused = name === 'all' ? null : name;
    [...charBox.children].forEach((x) => x.classList.toggle('on', x.dataset.char === name));
    refreshStats();
  }

  // ---- simple actions
  panel.querySelector('[data-act="all"]').onclick = () => {
    hooks.onFrameAll();
    setFocus('all');
  };
  const tourBtn = panel.querySelector('[data-act="tour"]');
  tourBtn.onclick = () => {
    const on = !tourBtn.classList.contains('on');
    tourBtn.classList.toggle('on', on);
    hooks.onAutoTour(on);
  };
  const moveAllBtn = panel.querySelector('[data-act="moveall"]');
  moveAllBtn.classList.add('on');
  state.moveAll = true;
  for (const c of chars) c.loco.setSpeed(state.speed);
  moveAllBtn.onclick = () => {
    const on = !moveAllBtn.classList.contains('on');
    moveAllBtn.classList.toggle('on', on);
    hooks.onMoveAll(on);
  };

  // ---- toggles
  panel.querySelectorAll('[data-tgl]').forEach((b) => {
    b.onclick = () => {
      const key = b.dataset.tgl;
      const on = !b.classList.contains('on');
      b.classList.toggle('on', on);
      hooks.onDebug({ [key]: on });
    };
  });

  // ---- ranges
  const speed = panel.querySelector('#speed');
  speed.oninput = () => hooks.onSpeed(parseFloat(speed.value));
  const bands = panel.querySelector('#bands');
  bands.oninput = () => hooks.onDebug({ bands: parseInt(bands.value, 10) });
  const seed = panel.querySelector('#seed');
  seed.oninput = () => { /* live drag is too expensive; commit on change */ };
  seed.onchange = () => hooks.onRegenerate(parseInt(seed.value, 10));
  panel.querySelector('[data-act="regen"]').onclick = () => {
    seed.value = String((parseInt(seed.value, 10) % 40) + 1);
    hooks.onRegenerate(parseInt(seed.value, 10));
  };

  // ---- click a character in the scene to inspect it
  const canvas = document.getElementById('c');
  canvas.addEventListener('click', (ev) => {
    // handled in main.js via screen-space picking; UI only reflects the result
  });

  function refreshStats() {
    const focused = chars.find((c) => c.preset === state.focused);
    const list = focused ? [focused] : chars;
    const lines = [];
    for (const c of list) {
      const s = c.stats();
      lines.push(
        `${s.preset.padEnd(10)} ${String(s.triangles).padStart(5)} tri  ${String(s.vertices).padStart(5)} v  ` +
        `${String(s.joints).padStart(2)} bones\n` +
        `           plan h ${s.height.toFixed(2)} → display ${(c.sceneScale).toFixed(2)}×  ` +
        `speed ${c.loco.forwardSpeed.toFixed(2)} m/s`,
      );
      if (c.remeshStats) {
        lines.push(`           remesh ${c.remeshStats.triangles} tri @${c.remeshStats.resolution} in ${c.remeshStats.ms} ms`);
      }
    }
    stats.innerHTML = lines.join('\n');
  }

  function tick(dt, st, list) {
    const arr = st.lastFrameMs.slice(-120);
    const sorted = [...arr].sort((a, b) => a - b);
    const p = (q) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : 0);
    const info = window.__AC0090 ? window.__AC0090.stats() : null;
    const head = info
      ? `fps ${(1000 / Math.max(0.01, st.frameMs)).toFixed(0)}  frame p50 ${p(0.5).toFixed(1)} p95 ${p(0.95).toFixed(1)} ms\n` +
        `draws ${info.drawCalls}  tris ${info.triangles}  programs ${info.programs}`
      : '';
    const focused = list.find((c) => c.preset === st.focused);
    const shown = focused ? [focused] : list;
    const body = shown.map((c) => {
      const s = c.stats();
      return `${s.preset.padEnd(10)} ${String(s.triangles).padStart(5)} tri ${String(s.joints).padStart(2)} bones ` +
        `${c.loco.stats.cycleHz.toFixed(2)} Hz ${(c.loco.stats.stride).toFixed(3)} m`;
    }).join('\n');
    stats.innerHTML = `${head}\n${'─'.repeat(34)}\n${body}`;
  }

  return {
    refresh() {
      buildCharButtons(chars);
      setFocus(state.focused || 'all');
      refreshStats();
    },
    setSpeed(v) {
      speed.value = String(v);
      hooks.onSpeed(v);
    },
    setFocus(name) { setFocus(name); hooks.onFocus(name === 'all' ? null : name); },
    syncFromState() {
      panel.querySelectorAll('[data-tgl]').forEach((b) => {
        b.classList.toggle('on', !!state[b.dataset.tgl]);
      });
      bands.value = String(state.bands);
      [...tierBox.children].forEach((x) => x.classList.toggle('on', x.dataset.tier === state.tier));
      tierNote.textContent = TIER_NOTE[state.tier];
      moveAllBtn.classList.toggle('on', !!state.moveAll);
    },
    tick,
  };
}
