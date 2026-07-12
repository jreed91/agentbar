'use strict';
const fs = require('fs');
const path = require('path');

// ---- Palette (exact hex from app/Sources/AgentBar/Views/FeedComponents.swift) ----
const C = {
  bg: '#080d0a', green: '#46e07f', text: '#8affb0', head: '#c8ffd8', sub: '#5fbf83',
  dim: '#3a7a52', ink: '#062012', amber: '#ffb000', amberText: '#ffce6b',
  stPermission: '#ff5f56', stQuestion: '#ffb000', stWorking: '#0a84ff', stDone: '#46e07f',
  moodPermission: '#ff6b5f', moodQuestion: '#ffce6b',
  kbdDeny: '#3a4a40', kbdFocus: '#2a5a3a',
  shDeny: '#1a2a20', shFocus: '#143020',
  // Source pill accents (design `AgentSource.tagColor`): phosphor green for Claude,
  // working-blue for Copilot, so a mixed roster reads at a glance.
  srcClaude: '#46e07f', srcCopilot: '#0a84ff',
};

const CSS = `
:root { color-scheme: dark; }
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { background: transparent; }
body { font-family: "DejaVu Sans Mono", ui-monospace, monospace; -webkit-font-smoothing: antialiased; }
.stage { padding: 30px; display: inline-block; }
.popover {
  width: 340px; background: ${C.bg}; border-radius: 7px;
  border: 1px solid rgba(70,224,127,0.4);
  box-shadow: 0 18px 46px rgba(0,0,0,0.55), 0 2px 8px rgba(0,0,0,0.4);
  position: relative; overflow: hidden;
}
/* CRT scanlines */
.popover::after {
  content: ""; position: absolute; inset: 0; pointer-events: none;
  background: repeating-linear-gradient(to bottom, rgba(0,0,0,0.16) 0 1px, transparent 1px 3px);
  mix-blend-mode: multiply; z-index: 5;
}
.row { display: flex; align-items: center; }

/* Title bar */
.titlebar {
  display: flex; align-items: center; gap: 8px;
  padding: 8px 11px; background: rgba(70,224,127,0.05);
  border-bottom: 1px solid rgba(70,224,127,0.22);
}
.titlebar .name { font-size: 10.5px; color: ${C.sub}; white-space: nowrap; }
.spacer { flex: 1; }
.live {
  font-size: 9px; font-weight: 700; letter-spacing: 0.7px; color: ${C.ink};
  background: ${C.green}; padding: 3px 6px; border-radius: 3px;
}
.icon { width: 12px; height: 12px; color: ${C.sub}; display: inline-block; }
.icon.on { color: ${C.green}; }

/* Hero */
.hero { display: flex; align-items: center; gap: 13px; padding: 13px 14px 10px; }
.mascot { font-size: 11px; font-weight: 700; line-height: 1.32; white-space: pre; }
.hero .col { display: flex; flex-direction: column; gap: 4px; }
.hero .label { font-size: 10px; letter-spacing: 1px; color: ${C.dim}; }
.hero .headline { font-size: 14px; font-weight: 700; color: ${C.head}; text-transform: uppercase; }
.hero .subline { font-size: 11px; color: ${C.sub}; }

/* Dashboard strip */
.strip { display: flex; align-items: center; gap: 14px; padding: 6px 12px; border-bottom: 1px solid rgba(70,224,127,0.14); }
.stat { display: flex; align-items: center; gap: 4px; }
.stat .sym { font-size: 10px; }
.stat .num { font-size: 11px; font-weight: 700; color: ${C.head}; }
.stat .lab { font-size: 10px; color: ${C.sub}; }
.stat.off .sym { color: rgba(58,122,82,0.5); }
.stat.off .num { color: ${C.dim}; }
.stat.off .lab { color: rgba(58,122,82,0.6); }

/* Feed */
.feed { padding: 0 12px 2px; }
.grouphdr { display: flex; align-items: center; gap: 6px; padding: 9px 0 1px; }
.grouphdr .title { font-size: 9.5px; font-weight: 700; letter-spacing: 1px; }
.grouphdr .cnt { font-size: 9.5px; font-weight: 700; color: ${C.dim}; }
.dashed { height: 1px; border-top: 1px dashed rgba(70,224,127,0.16); }

.line { padding: 8px 0; display: flex; flex-direction: column; gap: 5px; }
.line .hdr { display: flex; align-items: center; gap: 6px; }
.time { font-size: 10.5px; color: ${C.dim}; }
.proj { font-size: 12px; font-weight: 600; color: ${C.head}; white-space: nowrap; }
.msgs { font-size: 10px; color: ${C.dim}; }
.tag { font-size: 9.5px; font-weight: 700; letter-spacing: 0.5px; color: ${C.ink}; padding: 2px 4px; border-radius: 2px; }
.src { font-size: 8.5px; font-weight: 700; letter-spacing: 0.5px; padding: 1.5px 4px; border-radius: 2px; border: 1px solid; }
.title2 { font-size: 11px; color: ${C.text}; }

/* Session meta: model · permission-mode pill · context-window usage */
.meta { display: flex; align-items: center; gap: 7px; }
.meta .model { font-size: 9.5px; color: ${C.sub}; white-space: nowrap; }
.meta .mode { font-size: 8.5px; font-weight: 700; letter-spacing: 0.3px; color: ${C.ink}; padding: 1px 4px; border-radius: 2px; }
.meta .ctx { font-size: 9.5px; white-space: nowrap; }
.ask { font-size: 11px; font-weight: 500; }
.activity { font-size: 10.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.elapsed { font-size: 10px; }
.cmd {
  font-size: 11px; font-weight: 500; color: ${C.amberText};
  background: rgba(255,176,0,0.09); border: 1px solid rgba(255,176,0,0.3);
  border-radius: 4px; padding: 6px 8px;
}
.acts { display: flex; align-items: center; gap: 10px; padding-top: 2px; }
.kc { display: inline-flex; align-items: center; gap: 5px; }
.kc .key {
  font-size: 10px; font-weight: 700; color: ${C.text};
  padding: 3px 6px; min-width: 16px; text-align: center; border-radius: 3px;
  border-bottom: 2px solid transparent;
}
.kc .key.focus { background: ${C.kbdFocus}; border-bottom-color: ${C.shFocus}; }
.kc .key.deny { background: ${C.kbdDeny}; border-bottom-color: ${C.shDeny}; }
.kc .lab { font-size: 10.5px; color: ${C.sub}; }

/* trail */
.trail { margin-left: 12px; padding: 3px 0 0 12px; border-left: 1px solid rgba(70,224,127,0.18); display: flex; flex-direction: column; gap: 3px; }
.trail .te { display: flex; gap: 6px; }
.trail .tt { font-size: 9.5px; color: ${C.dim}; }
.trail .tl { font-size: 10px; color: ${C.sub}; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

/* history */
.histhdr { display: flex; align-items: center; padding: 6px 12px; }
.histhdr .t { font-size: 10px; font-weight: 700; letter-spacing: 1px; color: ${C.dim}; }
.histhdr .clear { font-size: 10px; color: ${C.sub}; }
.hline { padding: 7px 0; display: flex; flex-direction: column; gap: 4px; }
.hline .top { display: flex; align-items: center; gap: 6px; }
.hline .sum { font-size: 11px; color: ${C.text}; }

/* prompt bar */
.promptbar { display: flex; align-items: center; gap: 6px; padding: 9px 12px; border-top: 1px solid rgba(70,224,127,0.22); }
.promptbar .t { font-size: 11px; font-weight: 500; color: ${C.green}; }
.promptbar .keys { font-size: 9px; color: ${C.dim}; white-space: nowrap; }

/* resize handle */
.handle { display: flex; justify-content: center; padding: 4px 0; }
.handle .bar { width: 38px; height: 4px; border-radius: 2px; background: rgba(58,122,82,0.8); }
`;

// ---- Icons ----
const funnel = (on) => `<svg class="icon${on ? ' on' : ''}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M2 3h12l-4.5 5.5V13L6.5 11.5V8.5z"/></svg>`;
const clock = (on) => `<svg class="icon${on ? ' on' : ''}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M13.5 8a5.5 5.5 0 1 1-1.7-3.9"/><path d="M13.6 2.6V5h-2.4"/><path d="M8 5.2V8l2 1.4"/></svg>`;
// gearshape: a toothed ring with a hollow hub (approximates SF Symbols "gearshape")
const gear = `<svg class="icon" viewBox="0 0 16 16" fill="currentColor"><path fill-rule="evenodd" d="M6.9 1.2h2.2l.35 1.6c.5.16.97.43 1.37.78l1.55-.55 1.1 1.9-1.2 1.1c.05.26.08.53.08.8s-.03.54-.08.8l1.2 1.1-1.1 1.9-1.55-.55c-.4.35-.87.62-1.37.78l-.35 1.64H6.9l-.35-1.64a4 4 0 0 1-1.37-.78l-1.55.55-1.1-1.9 1.2-1.1a4.3 4.3 0 0 1 0-1.6l-1.2-1.1 1.1-1.9 1.55.55c.4-.35.87-.62 1.37-.78zM8 5.7A2.3 2.3 0 1 0 8 10.3 2.3 2.3 0 0 0 8 5.7z"/></svg>`;

// ---- Mascot faces ----
const faces = {
  happy:      '┌─────────┐\n│  ^   ^  │\n│    ‿    │\n└─────────┘',
  working:    '┌─────────┐\n│  -   -  │\n│   ───   │\n└─────────┘',
  question:   '┌─────────┐\n│  o   O  │\n│    ?    │\n└─────────┘',
  permission: '┌─────────┐\n│  O   O  │\n│    o    │\n└─────────┘',
  done:       '┌─────────┐\n│  ^   ^  │\n│   \\_/   │\n└─────────┘',
};
const moodColor = { happy: C.green, working: C.green, question: C.moodQuestion, permission: C.moodPermission, done: C.green };

// ---- Component builders ----
function mascot(mood) {
  const col = moodColor[mood];
  return `<div class="mascot" style="color:${col}; text-shadow:0 0 6px ${col}80">${faces[mood]}</div>`;
}
function statusColor(s) {
  return { PERMISSION: C.stPermission, ERROR: C.stPermission, QUESTION: C.stQuestion, WORKING: C.stWorking, DONE: C.stDone, IDLE: C.dim }[s];
}
function tag(s) { return `<span class="tag" style="background:${statusColor(s)}">${s}</span>`; }
// Source pill (CLAUDE / COPILOT) — outlined so it sits quietly beside the filled status tag.
function sourceTag(src) {
  const col = src === 'COPILOT' ? C.srcCopilot : C.srcClaude;
  return `<span class="src" style="color:${col}; border-color:${col}80">${src}</span>`;
}
function keycap(key, lab, style) { return `<span class="kc"><span class="key ${style}">${key}</span><span class="lab">${lab}</span></span>`; }

// The model · mode · context-usage meta line under a row's header. Mirrors QueueView.metaLine:
// only the pieces we know are shown, and a Copilot row (no model/mode/ctx) renders nothing.
const modeColor = { 'plan': C.stWorking, 'accept edits': C.stDone, 'bypass': C.stPermission, 'default': C.dim };
function ctxColor(pct) { return pct >= 90 ? C.stPermission : pct >= 75 ? C.amberText : C.dim; }
function metaLine(o) {
  if (!o.model && !o.mode && o.ctx == null) return '';
  let parts = '';
  if (o.model) parts += `<span class="model">${o.model}</span>`;
  if (o.mode) parts += `<span class="mode" style="background:${modeColor[o.mode] || C.dim}">${o.mode}</span>`;
  if (o.ctx != null) parts += `<span class="ctx" style="color:${ctxColor(o.ctxPct)}">ctx ${o.ctx} · ${o.ctxPct}%</span>`;
  return `<div class="meta">${parts}</div>`;
}

function titlebar(count, { filter = false, history = false } = {}) {
  return `<div class="titlebar">
    <span class="name">agentbar — ${count} ${count === 1 ? 'session' : 'sessions'}</span>
    <span class="spacer"></span>
    <span class="live">LIVE</span>
    ${funnel(filter)}
    ${clock(history)}
    ${gear}
  </div>`;
}
function hero(mood, headline, subline) {
  return `<div class="hero">
    ${mascot(mood)}
    <div class="col">
      <div class="label">┌ STATUS</div>
      <div class="headline">${headline}</div>
      <div class="subline">${subline}</div>
    </div>
  </div>`;
}
function strip(needs, working, idle) {
  const cell = (sym, n, lab, col) => `<div class="stat ${n > 0 ? '' : 'off'}"><span class="sym" style="color:${n > 0 ? col : ''}">${sym}</span><span class="num">${n}</span><span class="lab">${lab}</span></div>`;
  return `<div class="strip">
    ${cell('●', needs, 'need you', C.stPermission)}
    ${cell('⚙', working, 'working', C.stWorking)}
    ${cell('○', idle, 'idle', C.dim)}
  </div>`;
}
function groupHeader(sym, title, count, col) {
  return `<div class="grouphdr"><span class="title" style="color:${col}">${sym} ${title}</span><span class="cnt">${count}</span></div>`;
}

// A session line. opts: time, proj, status, msgs, title, ask, askColor, elapsed, elapsedColor, cmd, activity, activityColor, acts:[[key,lab,style]], trail:[[t,l]]
function line(o) {
  const src = sourceTag(o.source || 'CLAUDE');
  let inner = `<div class="hdr"><span class="time">${o.time}</span><span class="proj">[${o.proj}]</span>${tag(o.status)}${src}<span class="spacer"></span>${o.msgs ? `<span class="msgs">${o.msgs} msgs</span>` : ''}</div>`;
  inner += metaLine(o);
  inner += `<div class="title2">└─ ${o.title}</div>`;
  if (o.activity) inner += `<div class="activity" style="color:${o.activityColor}">⋯ ${o.activity}</div>`;
  if (o.workingElapsed) inner += `<div class="elapsed" style="color:${C.stWorking}bf">working ${o.workingElapsed}</div>`;
  if (o.ask) inner += `<div class="ask" style="color:${o.askColor}">→ ${o.ask}</div>`;
  if (o.elapsed) inner += `<div class="elapsed" style="color:${o.elapsedColor}bf">waiting ${o.elapsed}</div>`;
  if (o.cmd) inner += `<div class="cmd">$ ${o.cmd}</div>`;
  if (o.acts) inner += `<div class="acts">${o.acts.map(a => keycap(a[0], a[1], a[2])).join('')}</div>`;
  if (o.trail) inner += `<div class="trail">${o.trail.map(t => `<div class="te"><span class="tt">${t[0]}</span><span class="tl">${t[1]}</span></div>`).join('')}</div>`;
  return `<div class="line">${inner}</div>`;
}
function promptbar(n, { keys = true } = {}) {
  return `<div class="promptbar"><span class="t">◉ watching ${n} ${n === 1 ? 'session' : 'sessions'} · notify-only</span><span class="spacer"></span>${keys ? '<span class="keys">↑↓ ↵ d m</span>' : ''}</div>`;
}
function handle() { return `<div class="handle"><span class="bar"></span></div>`; }

function page(popoverInner) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${CSS}</style></head><body><div class="stage"><div class="popover">${popoverInner}</div></div></body></html>`;
}

// ================= STATE 1: Multi-agent dashboard =================
const dashboard = page(
  titlebar(5) +
  hero('permission', '2 things need you', '1 permission · 1 question') +
  strip(2, 1, 2) +
  `<div class="feed">` +
    groupHeader('●', 'NEEDS YOU', 2, C.stPermission) +
    line({
      time: '14:32:07', proj: 'agentbar', status: 'PERMISSION', msgs: 148,
      model: 'opus-4-8', mode: 'default', ctx: '214k', ctxPct: 21,
      title: 'wire up the release workflow and cask',
      ask: 'Wants to run Bash', askColor: C.stPermission,
      elapsed: '18s', elapsedColor: C.stPermission,
      cmd: 'make bundle install',
      acts: [['↵', 'focus', 'focus'], ['d', 'dismiss', 'deny'], ['m', 'mute', 'deny']],
    }) +
    `<div class="dashed"></div>` +
    line({
      time: '14:31:55', proj: 'notes-api', status: 'QUESTION', msgs: 62,
      model: 'sonnet-4-5', mode: 'plan', ctx: '88k', ctxPct: 44,
      title: 'add pagination to the search endpoint',
      ask: 'Which page size should be the default?', askColor: C.stQuestion,
      elapsed: '31s', elapsedColor: C.stQuestion,
      acts: [['↵', 'focus', 'focus'], ['d', 'dismiss', 'deny'], ['m', 'mute', 'deny']],
    }) +
    groupHeader('⚙', 'WORKING', 1, C.stWorking) +
    line({
      time: '14:32:09', proj: 'web-dashboard', status: 'WORKING', msgs: 90,
      model: 'sonnet-4-5', mode: 'accept edits', ctx: '152k', ctxPct: 76,
      title: 'migrate the charts to the new theme tokens',
      activity: 'Editing ThemeTokens.ts', activityColor: C.stWorking,
      workingElapsed: '2m 13s',
      acts: [['↵', 'focus', 'focus'], ['›', 'trail', 'focus']],
    }) +
    groupHeader('○', 'IDLE', 2, C.dim) +
    line({
      time: '14:20:41', proj: 'infra', status: 'DONE', msgs: 210,
      model: 'haiku-4-5', mode: 'default', ctx: '34k', ctxPct: 17,
      title: 'bump the terraform providers',
      activity: 'finished in 4m 02s', activityColor: C.dim,
      acts: [['↵', 'focus', 'focus'], ['›', 'trail', 'focus']],
    }) +
    `<div class="dashed"></div>` +
    line({
      time: 'Jul 10', proj: 'cli-tools', status: 'IDLE', msgs: 34, source: 'COPILOT',
      title: 'add a --json flag to the status command',
      acts: [['↵', 'focus', 'focus']],
    }) +
  `</div>` +
  promptbar(5) +
  handle()
);

// ================= STATE 2: Permission close-up =================
const permission = page(
  titlebar(2) +
  hero('permission', 'Permission needed', 'Claude wants to run a command.') +
  strip(1, 0, 1) +
  `<div class="feed">` +
    groupHeader('●', 'NEEDS YOU', 1, C.stPermission) +
    line({
      time: '09:14:52', proj: 'agentbar', status: 'PERMISSION', msgs: 73,
      model: 'opus-4-8', mode: 'accept edits', ctx: '156k', ctxPct: 78,
      title: 'set up the homebrew cask and release build',
      ask: 'Wants to run Bash', askColor: C.stPermission,
      elapsed: '12s', elapsedColor: C.stPermission,
      cmd: 'git push -u origin release/v0.4.0',
      acts: [['↵', 'focus', 'focus'], ['d', 'dismiss', 'deny'], ['m', 'mute', 'deny'], ['›', 'trail', 'focus']],
      trail: [
        ['09:14:31', 'Running: swift build'],
        ['09:14:12', 'Editing Casks/agentbar.rb'],
        ['09:13:58', 'Reading scripts/release-build.sh'],
      ],
    }) +
    groupHeader('○', 'IDLE', 1, C.dim) +
    line({
      time: '08:52:10', proj: 'docs-site', status: 'IDLE', msgs: 19,
      model: 'sonnet-4-5', mode: 'default', ctx: '41k', ctxPct: 21,
      title: 'update the install instructions',
      acts: [['↵', 'focus', 'focus']],
    }) +
  `</div>` +
  promptbar(2) +
  handle()
);

// ================= STATE 3: Recent activity log =================
const activityLog = page(
  titlebar(5, { history: true }) +
  hero('done', 'Task complete', 'Recent activity below.') +
  `<div class="histhdr"><span class="t">RECENT ACTIVITY</span><span class="spacer"></span><span class="clear">clear</span></div>` +
  `<div class="feed">` +
    (() => {
      const rows = [
        ['14:32:07', 'PERMISSION', 'agentbar', 'Wants to run Bash: make bundle install'],
        ['14:31:55', 'QUESTION', 'notes-api', 'Which page size should be the default?'],
        ['14:30:18', 'DONE', 'web-dashboard', 'Finished in 2m 44s'],
        ['14:24:03', 'WORKING', 'infra', 'Started a turn — migrating providers'],
        ['14:21:09', 'DONE', 'cli-tools', 'Copilot finished — added the --json flag'],
        ['14:20:41', 'DONE', 'infra', 'Finished in 4m 02s'],
        ['14:02:37', 'ERROR', 'notes-api', 'Run interrupted — API rate limit'],
      ];
      return rows.map((r, i) =>
        (i > 0 ? '<div class="dashed"></div>' : '') +
        `<div class="hline"><div class="top"><span class="time">${r[0]}</span>${tag(r[1])}<span class="proj">[${r[2]}]</span></div><div class="sum">${r[3]}</div></div>`
      ).join('');
    })() +
  `</div>` +
  promptbar(5) +
  handle()
);

const outDir = process.argv[2] || '.';
fs.writeFileSync(path.join(outDir, 'dashboard.html'), dashboard);
fs.writeFileSync(path.join(outDir, 'permission.html'), permission);
fs.writeFileSync(path.join(outDir, 'activity.html'), activityLog);
console.log('wrote dashboard.html, permission.html, activity.html to', outDir);
