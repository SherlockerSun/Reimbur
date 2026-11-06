'use strict';

const C = window.ReimburCore;
const API = window.reimbur || createBrowserFallback();
const STATUS_COLORS = { '未报销': '#f39a3f', '待审批': '#3f96ff', '已归档': '#35ad78' };
const EXPENSE_ICONS = { '出差补助': '¥', '火车': '铁', '飞机': '机', '打车': '车', '住宿': '住', '餐补': '餐', '补助': '补' };
const state = {
  claims: [], selectedId: null, view: 'home', kindFilter: null, status: '', period: '', search: '',
  batch: false, checked: new Set(), menuCollapsed: false, recordsCollapsed: false,
  selectedExpenseType: '出差补助', calendarMonth: new Date(), ledgerSort: { column: '', ascending: null },
  settings: loadSettings(), dataPath: null, appVersion: '1.0.0', busy: false, personTab: '总览'
};
let saveTimer = null;
let toastTimer = null;
let previewState = null;
let modalSummaryTab = '总览';
let contextMenu = null;

function createBrowserFallback() {
  const key = 'reimbur-browser-claims';
  let files = {};
  const get = () => JSON.parse(localStorage.getItem(key) || '[]');
  return {
    listClaims: async () => get(),
    saveClaim: async claim => {
      const claims = get().filter(item => item.id !== claim.id);
      claims.unshift(claim); localStorage.setItem(key, JSON.stringify(claims)); return claim;
    },
    deleteClaims: async ids => localStorage.setItem(key, JSON.stringify(get().filter(item => !ids.includes(item.id)))),
    dataPath: async () => ({ root: '浏览器预览模式', database: 'localStorage', attachments: '' }),
    openDataDir: async () => true, copyText: async text => navigator.clipboard?.writeText(text),
    openExternal: async url => window.open(url, '_blank'), importAttachments: async () => [],
    readAttachment: async () => { throw new Error('浏览器预览模式不支持本地附件'); }, duplicateAttachment: async () => { throw new Error('浏览器预览模式不支持复制附件'); }, copyAttachmentFile: async () => true,
    deleteAttachment: async () => true, exportAttachmentZip: async () => null,
    exportLedger: async () => null, exportPrintDocx: async () => null, appVersion: async () => '1.0.0-dev',
    onNew: () => {}, onHome: () => {}, onSettings: () => {}
  };
}

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[char]));
}
function attr(value) { return escapeHTML(value).replaceAll('\n', '&#10;'); }
function iconText(name) {
  return ({ settings: '⚙', home: '⌂', close: '×', previous: '‹', next: '›', copy: '⧉', download: '⇩', add: '+', search: '⌕', eye: '◉' })[name] || name;
}
function getClaim() { return state.claims.find(claim => claim.id === state.selectedId) || null; }
function loadSettings() {
  try { return { ...C.defaultSettings(), ...JSON.parse(localStorage.getItem('reimbur-windows-settings') || '{}') }; }
  catch (_) { return C.defaultSettings(); }
}
function saveSettings() { localStorage.setItem('reimbur-windows-settings', JSON.stringify(state.settings)); }
function setByPath(object, path, value) {
  const parts = path.split('.');
  let target = object;
  for (let index = 0; index < parts.length - 1; index++) {
    const part = parts[index];
    if (!(part in target)) target[part] = {};
    target = target[part];
  }
  target[parts[parts.length - 1]] = value;
}

function showToast(message, error = false) {
  const element = document.getElementById('toast');
  element.textContent = message;
  element.classList.toggle('error', error);
  element.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => element.classList.add('hidden'), error ? 4800 : 2600);
}

function showError(error) {
  console.error(error);
  showToast(error?.message || String(error), true);
}

function queueSave({ sidebar = false, main = false } = {}) {
  const claim = getClaim();
  if (!claim) return;
  claim.updatedAt = new Date().toISOString();
  C.normalize(claim);
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    try {
      claim.updatedAt = new Date().toISOString();
      await API.saveClaim(claim);
      const index = state.claims.findIndex(item => item.id === claim.id);
      if (index >= 0) state.claims[index] = claim;
      if (sidebar) renderSidebar();
      if (main) renderMain();
    } catch (error) { showError(error); }
  }, 260);
}

async function saveNow() {
  clearTimeout(saveTimer);
  const claim = getClaim();
  if (!claim) return;
  claim.updatedAt = new Date().toISOString();
  const saved = await API.saveClaim(claim);
  Object.assign(claim, saved);
}

async function init() {
  document.getElementById('main-content').innerHTML = '<div class="loading-screen"><div><div class="spinner" style="margin:0 auto 12px"></div>正在载入本地数据…</div></div>';
  try {
    [state.claims, state.dataPath, state.appVersion] = await Promise.all([API.listClaims(), API.dataPath(), API.appVersion()]);
    state.claims.forEach(C.normalize);
    document.getElementById('tagline').textContent = state.settings.caption;
    bindGlobalEvents();
    if (state.settings.startup === 'last' && state.claims[0]) {
      state.selectedId = state.claims[0].id;
      state.view = 'claim';
    }
    renderAll();
  } catch (error) {
    showError(error);
    document.getElementById('main-content').innerHTML = `<div class="empty-state"><div><div class="empty-icon">!</div><h1>数据加载失败</h1><p class="subtitle">${escapeHTML(error.message || error)}</p></div></div>`;
  }
}

function bindGlobalEvents() {
  document.body.addEventListener('click', handleClick);
  document.body.addEventListener('contextmenu', handleContextMenu);
  document.body.addEventListener('change', handleChange);
  document.body.addEventListener('input', handleInput);
  document.body.addEventListener('keydown', handleKeydown);
  document.addEventListener('mousedown', event => {
    if (contextMenu && !contextMenu.contains(event.target) && !event.target.closest('.record-item')) closeContextMenu();
  });
  window.addEventListener('pointerup', finishCalendarSweep);
  document.getElementById('modal-backdrop').addEventListener('click', closeModal);
  document.getElementById('record-search').addEventListener('input', event => { state.search = event.target.value; renderSidebar(); });
  document.getElementById('status-filter').addEventListener('change', event => { state.status = event.target.value; renderSidebar(); });
  document.getElementById('period-filter').addEventListener('change', event => { state.period = event.target.value; renderSidebar(); });
  API.onNew(kind => createClaim(kind));
  API.onHome(() => showHome());
  API.onSettings(() => showSettings());
  window.addEventListener('keydown', event => {
    if (event.key === 'Escape') { closeContextMenu(); closeModal(); }
  });
}

function renderAll() { renderSidebar(); renderMain(); }

function filteredRecords() {
  return C.filterClaims(state.claims, { kind: state.kindFilter, status: state.status, period: state.period, search: state.search });
}

function renderSidebar() {
  const records = filteredRecords();
  document.getElementById('count-出差').textContent = state.claims.filter(c => c.kind === '出差').length;
  document.getElementById('count-餐补').textContent = state.claims.filter(c => c.kind === '餐补').length;
  document.getElementById('count-补助').textContent = state.claims.filter(c => c.kind === '补助').length;
  document.getElementById('record-summary').textContent = `${records.length} 条`;
  document.querySelectorAll('.nav-item[data-view], .nav-item[data-kind]').forEach(button => {
    const active = (button.dataset.view === 'home' && state.view === 'home') ||
      (button.dataset.kind && state.view === 'claim' && state.kindFilter === button.dataset.kind);
    button.classList.toggle('active', active);
  });
  document.getElementById('settings-button').classList.toggle('active', state.view === 'settings');
  document.getElementById('sidebar').classList.toggle('collapsed', state.menuCollapsed);
  const recordSection = document.getElementById('record-section');
  recordSection.classList.toggle('collapsed', state.recordsCollapsed);
  document.getElementById('records-toggle').classList.toggle('collapsed', state.recordsCollapsed);
  document.getElementById('records-toggle').title = state.recordsCollapsed ? '展开报销记录' : '折叠报销记录';
  document.getElementById('batch-bar').classList.toggle('hidden', !state.batch);
  document.getElementById('tagline').textContent = state.settings.caption;

  const periods = new Set();
  for (const claim of state.claims) for (const date of C.reimbursementDates(claim)) periods.add(date.slice(0, 7));
  const periodSelect = document.getElementById('period-filter');
  const currentPeriod = state.period;
  periodSelect.innerHTML = '<option value="">全部时间</option>' + [...periods].sort().reverse().map(period => `<option value="${period}">${period.replace('-', ' 年 ')} 月</option>`).join('');
  periodSelect.value = currentPeriod;
  document.getElementById('status-filter').value = state.status;

  const list = document.getElementById('record-list');
  if (!records.length) {
    list.innerHTML = `<div style="padding:18px 9px;color:rgba(255,255,255,.35);font-size:10.5px;text-align:center">${state.claims.length ? '没有匹配的报销记录' : '暂无报销记录'}</div>`;
    return;
  }
  list.innerHTML = records.map(claim => `
    <div class="record-item ${claim.id === state.selectedId && state.view === 'claim' ? 'active' : ''}" data-action="open-record" data-id="${attr(claim.id)}" data-status="${attr(claim.savedStatus)}" tabindex="0">
      ${state.batch ? `<input class="record-check" type="checkbox" data-action="check-record" data-id="${attr(claim.id)}" ${state.checked.has(claim.id) ? 'checked' : ''}>` : ''}
      <div class="record-title-line"><span class="status-dot"></span><span class="record-title">${escapeHTML(claim.title)}</span></div>
      <div class="record-meta">${escapeHTML(claim.savedStatus)} · ${escapeHTML(C.recordDetail(claim))}</div>
    </div>
  `).join('');
}

function showHome() {
  state.view = 'home'; state.kindFilter = null; renderAll();
}
function showKind(kind) {
  state.kindFilter = kind;
  const current = getClaim();
  if (!current || current.kind !== kind) {
    const first = state.claims.find(claim => claim.kind === kind);
    state.selectedId = first?.id || null;
  }
  state.view = 'claim';
  renderAll();
}
function showSettings() { state.view = 'settings'; renderAll(); }

async function createClaim(kind = state.kindFilter) {
  if (!kind) { openKindPicker(); return; }
  try {
    await saveNow();
    const claim = C.normalize(C.createClaim(kind, state.settings));
    const saved = await API.saveClaim(claim);
    state.claims.unshift(saved);
    state.selectedId = saved.id;
    state.kindFilter = kind;
    state.view = 'claim';
    state.selectedExpenseType = kind === '出差' ? '出差补助' : (kind === '餐补' ? '餐补' : '补助');
    renderAll();
  } catch (error) { showError(error); }
}

function openKindPicker() {
  openModal(`
    <div class="modal-card small">
      <div class="modal-header"><div><h2>新建报销</h2><p>选择本次要创建的报销类型</p></div><button class="btn icon-only" data-action="close-modal">×</button></div>
      <div class="modal-body" style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px">
        ${C.KINDS.map(kind => `<button class="card btn" style="padding:22px 10px;display:grid;gap:8px" data-action="create-kind" data-kind="${kind}"><span style="font-size:24px">${EXPENSE_ICONS[kind]}</span><strong>${escapeHTML(C.displayKind(kind))}报销</strong></button>`).join('')}
      </div>
    </div>`);
}

function renderMain() {
  if (state.view === 'settings') renderSettings();
  else if (state.view === 'claim' && getClaim()) renderClaim();
  else if (state.view === 'claim' && state.kindFilter) renderEmptyKind();
  else renderHome();
}

function pageHeader({ eyebrow, title, subtitle = '', actions = '' }) {
  return `<div class="page-header"><div class="page-heading"><div class="eyebrow">${escapeHTML(eyebrow)}</div><h1>${escapeHTML(title)}</h1>${subtitle ? `<p class="subtitle">${escapeHTML(subtitle)}</p>` : ''}</div><div class="header-actions">${actions}</div></div>`;
}

function renderEmptyKind() {
  const kind = state.kindFilter;
  document.getElementById('main-content').innerHTML = `${pageHeader({ eyebrow: `${C.displayKind(kind)}报销`, title: `${C.displayKind(kind)}报销记录`, actions: `<button class="btn primary" data-action="new-claim">+ 新建${escapeHTML(C.displayKind(kind))}报销</button>` })}
    <div class="card empty-state"><div><div class="empty-icon">${EXPENSE_ICONS[kind]}</div><h2>还没有${escapeHTML(C.displayKind(kind))}报销记录</h2><p class="subtitle">点击右上角按钮创建第一条记录。</p></div></div>`;
}

function renderHome() {
  const period = state.period;
  const result = C.stats(state.claims, period);
  const records = result.records;
  const months = monthSeries(records);
  const statusCounts = C.STATUSES.map(status => records.filter(claim => claim.savedStatus === status).length);
  const statusTotal = Math.max(1, statusCounts.reduce((a, b) => a + b, 0));
  let current = 0;
  const segments = statusCounts.map((count, index) => {
    const start = current / statusTotal * 360; current += count;
    return `${STATUS_COLORS[C.STATUSES[index]]} ${start}deg ${current / statusTotal * 360}deg`;
  });
  if (!segments.length) segments.push('#e5edf6 0deg 360deg');
  const recent = [...records].sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))).slice(0, 5);
  const totalInvoice = records.reduce((sum, claim) => sum + C.invoiceTotal(claim), 0);
  document.getElementById('main-content').innerHTML = `
    ${pageHeader({
      eyebrow: 'OVERVIEW', title: '报销概览', subtitle: '查看全部本地报销记录的金额、发票和审批状态',
      actions: `<label class="field" style="width:150px"><span class="field-label">时间范围</span><select id="home-period">${periodOptions()}</select></label>`
    })}
    <section class="stats-grid">
      ${statCard('报销天数', result.days, '天', '按每条记录最大出差天数计算')}
      ${statCard('报销总额', C.formatMoney(result.total), '', `${records.length} 条有效记录`)}
      ${statCard('发票总额', C.formatMoney(result.invoiceTotal), '', '仅统计发票票面金额')}
      ${statCard('发票数量', result.invoiceCount, '份', '行程单与报销单不计入')}
    </section>
    <section class="dashboard-grid">
      <div class="card"><div class="card-header"><div><h2>月度报销金额</h2><p>悬浮柱形查看当月记录与发票明细</p></div></div><div class="card-body"><div class="chart-frame"><div class="bar-chart">${renderBars(months)}</div></div></div></div>
      <div class="card"><div class="card-header"><div><h2>审批状态分布</h2><p>未报销、待审批与已归档记录占比</p></div></div><div class="card-body"><div class="pie-layout"><div class="pie-chart" style="background:conic-gradient(${segments.join(',')})"></div><div class="pie-legend">${C.STATUSES.map((status, index) => `<div class="legend-row"><span class="legend-dot" style="background:${STATUS_COLORS[status]}"></span><span>${status}</span><strong>${statusCounts[index]}</strong></div>`).join('')}</div></div></div></div>
    </section>
    <section class="lower-grid">
      <div class="card"><div class="card-header"><div><h2>最近报销</h2><p>最近创建的记录</p></div><button class="btn soft" data-action="show-all-trip">查看记录</button></div><div class="card-body"><div class="mini-list">${recent.length ? recent.map(claim => `<div class="mini-row"><span class="status-pill" data-status="${attr(claim.savedStatus)}">${escapeHTML(claim.savedStatus)}</span><span class="name">${escapeHTML(claim.title)}</span><span class="amount">${C.formatMoney(C.claimTotal(claim))}</span></div>`).join('') : '<div class="empty-state" style="min-height:150px"><div>暂无报销记录</div></div>'}</div></div></div>
      <div class="card"><div class="card-header"><div><h2>类型分布</h2><p>不同报销类型的金额占比</p></div></div><div class="card-body"><div class="mini-list">${C.KINDS.map(kind => { const subset = records.filter(c => c.kind === kind); const amount = subset.reduce((sum, claim) => sum + C.claimTotal(claim), 0); return `<div class="mini-row"><span class="legend-dot" style="background:${kind === '出差' ? '#3f96ff' : kind === '餐补' ? '#f39a3f' : '#35ad78'}"></span><span class="name">${escapeHTML(C.displayKind(kind))}报销 · ${subset.length} 条</span><span class="amount">${C.formatMoney(amount)}</span></div>`; }).join('')}</div><div class="settings-help" style="margin-top:12px">发票合计 ${C.formatMoney(totalInvoice)}，报销差额 ${C.formatMoney(result.total - totalInvoice)}。</div></div></div>
    </section>`;
  document.getElementById('home-period').addEventListener('change', event => { state.period = event.target.value; renderSidebar(); renderHome(); });
  document.querySelectorAll('.bar-column[data-month]').forEach(column => {
    column.addEventListener('mouseenter', event => showBarTooltip(event, column.dataset.month));
    column.addEventListener('mousemove', event => moveTooltip(event));
    column.addEventListener('mouseleave', hideTooltip);
  });
}
function statCard(label, value, unit, hint) { return `<div class="stat-card"><div class="label">${escapeHTML(label)}</div><div class="value">${escapeHTML(value)}<span style="font-size:12px;font-weight:500;margin-left:3px">${escapeHTML(unit)}</span></div><div class="hint">${escapeHTML(hint)}</div></div>`; }
function monthSeries(records) {
  const now = new Date(); const points = [];
  for (let offset = 5; offset >= 0; offset--) {
    const date = new Date(now.getFullYear(), now.getMonth() - offset, 1); const key = `${date.getFullYear()}-${C.pad(date.getMonth() + 1)}`;
    const items = records.filter(claim => C.reimbursementDates(claim).some(value => value.startsWith(key)) || (!C.reimbursementDates(claim).length && C.dayKey(claim.createdAt).startsWith(key)));
    points.push({ key, date, items, amount: items.reduce((sum, claim) => sum + C.claimTotal(claim), 0) });
  }
  return points;
}
function renderBars(points) {
  const max = Math.max(1, ...points.map(point => point.amount));
  return points.map(point => `<div class="bar-column" data-month="${point.key}"><span>${Math.round(point.amount / 100).toLocaleString('zh-CN')}</span><div class="bar-fill" style="height:${Math.max(2, point.amount / max * 78)}%"></div><span>${point.date.getMonth() + 1}月</span></div>`).join('');
}
function periodOptions() {
  const periods = new Set();
  for (const claim of state.claims) for (const date of C.reimbursementDates(claim)) periods.add(date.slice(0, 7));
  return '<option value="">全部时间</option>' + [...periods].sort().reverse().map(period => `<option value="${period}" ${state.period === period ? 'selected' : ''}>${period}</option>`).join('');
}
function showBarTooltip(event, month) {
  hideTooltip();
  const point = monthSeries(C.stats(state.claims, state.period).records).find(item => item.key === month);
  if (!point) return;
  const tooltip = document.createElement('div'); tooltip.id = 'chart-tooltip'; tooltip.className = 'chart-tooltip';
  tooltip.innerHTML = `<strong>${month}</strong><br>报销总额 ${C.formatMoney(point.amount)}<br>${point.items.length} 条记录 · ${point.items.reduce((sum, claim) => sum + C.invoiceCount(claim), 0)} 份发票<br>发票总额 ${C.formatMoney(point.items.reduce((sum, claim) => sum + C.invoiceTotal(claim), 0))}`;
  document.body.appendChild(tooltip); moveTooltip(event);
}
function moveTooltip(event) {
  const tooltip = document.getElementById('chart-tooltip'); if (!tooltip) return;
  const left = Math.min(innerWidth - tooltip.offsetWidth - 12, event.clientX + 14); const top = Math.min(innerHeight - tooltip.offsetHeight - 12, event.clientY + 14);
  tooltip.style.left = `${Math.max(12, left)}px`; tooltip.style.top = `${Math.max(12, top)}px`;
}
function hideTooltip() { document.getElementById('chart-tooltip')?.remove(); }

function renderClaim() {
  const claim = getClaim();
  if (!claim) { renderHome(); return; }
  C.normalize(claim);
  const canCollapseRecord = true;
  const main = document.getElementById('main-content');
  main.innerHTML = `
    ${pageHeader({
      eyebrow: `${C.displayKind(claim.kind)}报销`,
      title: '', subtitle: '',
      actions: `
        <button class="btn" data-action="toggle-records" title="${state.recordsCollapsed ? '展开报销记录' : '折叠报销记录'}">${state.recordsCollapsed ? '展开记录' : '折叠记录'}</button>
        <button class="btn" data-action="preview-summary">◉ 预览清单</button>
        ${claim.kind === '出差' ? '<button class="btn" data-action="preview-form">▤ 报销单</button>' : ''}
        <button class="btn" data-action="export-invoices">⇩ 导出发票</button>
        <button class="btn" data-action="export-print">▣ 打印发票</button>`
    }).replace('<h1></h1>', `<input class="title-input" data-field="title" value="${attr(claim.title)}" aria-label="报销名称">`) }
    <div class="editor-layout">
      ${renderBasicCard(claim)}
      ${claim.kind === '出差' ? renderTripEditor(claim) : renderSimpleEditor(claim)}
      ${renderLedgerCard(claim)}
      ${claim.kind === '出差' ? renderPersonDetailCard(claim) : ''}
    </div>`;
  bindClaimViewEvents();
}

function renderBasicCard(claim) {
  const purpose = claim.kind === '出差' ? claim.tripPurpose : claim.reimbursementPurpose;
  const dateSpan = claim.kind === '餐补' ? 'span-9' : 'span-6';
  const noteSpan = claim.kind === '出差' ? 'span-6' : 'span-12';
  return `<section class="card">
    <div class="card-header"><div><h2>基本信息与报销明细</h2><p>修改后自动保存；出差人输入后按回车或离开输入框确认</p></div>
      <span class="status-pill" data-status="${attr(claim.savedStatus)}">${escapeHTML(claim.savedStatus)}</span>
    </div>
    <div class="card-body">
      <div class="field-grid">
        <div class="field span-3"><label>报销状态</label><select data-field="savedStatus">${C.STATUSES.map(status => `<option ${claim.savedStatus === status ? 'selected' : ''}>${status}</option>`).join('')}</select></div>
        <div class="field span-3"><label>部门</label><input data-field="department" value="${attr(claim.department)}" placeholder="填写部门"></div>
        <div class="field span-6"><label>${claim.kind === '出差' ? '出差人' : '报销人'}</label>${travelerTagInput(claim)}</div>
        <div class="field span-6"><label>${claim.kind === '出差' ? '出差事由' : '用途'}</label><input data-field="${claim.kind === '出差' ? 'tripPurpose' : 'reimbursementPurpose'}" value="${attr(purpose)}" placeholder="${claim.kind === '出差' ? '填写出差事由' : '填写报销用途'}"></div>
        ${claim.kind === '补助' ? `<div class="field span-3"><label>报销总额（元）</label><input data-money-field="allowanceAmount" inputmode="decimal" value="${C.inputMoney(claim.allowanceAmount || 0)}"></div>` : ''}
        ${claim.kind === '餐补' ? `<div class="field span-3"><label>餐补单价（元/天）</label><input data-expense-money="${attr(claim.expenses[0]?.id)}" data-property="unitPrice" inputmode="decimal" value="${C.inputMoney(claim.expenses[0]?.unitPrice || 0)}"></div>` : ''}
        ${claim.kind !== '补助' ? `<div class="field ${dateSpan}"><label>报销日期</label>${renderCalendar(claim)}</div>` : `<div class="field span-8" style="align-content:end"><div class="settings-help">补贴报销没有日期和每日单价，报销总额在上方单独填写；发票清单只统计发票。</div></div>`}
        <div class="field ${noteSpan}"><label>备注</label><textarea data-field="note" placeholder="填写备注信息">${escapeHTML(claim.note)}</textarea></div>
        <div class="field span-12"><div style="display:flex;align-items:center;justify-content:space-between;gap:12px"><label>报销单附件</label><button class="btn soft" data-action="upload-cover">⇧ 上传报销单</button></div>${(claim.covers || []).length ? `<div style="margin-top:7px">${claim.covers.map(file => fileChip(file, ['cover', '', file.id])).join(' ')}</div>` : '<div class="settings-help">支持图片或 PDF；打印发票时会排在最上方。</div>'}</div>
      </div>
    </div>
  </section>`;
}

function travelerTagInput(claim) {
  return `<div class="tag-input-shell" id="traveler-input-shell">
    ${(claim.travelerNames || []).map(name => `<span class="tag">${escapeHTML(name)}<button type="button" data-action="remove-traveler" data-name="${attr(name)}" title="移除${attr(name)}">×</button></span>`).join('')}
    <input id="traveler-input" placeholder="${claim.travelerNames?.length ? '' : '输入姓名后回车'}" autocomplete="off">
  </div>`;
}

function renderCalendar(claim) {
  const selected = new Set(claim.dates || []);
  const first = new Date(state.calendarMonth.getFullYear(), state.calendarMonth.getMonth(), 1);
  const firstWeekday = (first.getDay() + 6) % 7;
  const start = new Date(first); start.setDate(1 - firstWeekday);
  const days = [];
  for (let index = 0; index < 42; index++) {
    const date = new Date(start); date.setDate(start.getDate() + index); const key = C.dayKey(date);
    days.push({ date, key, current: date.getMonth() === first.getMonth(), selected: selected.has(key) });
  }
  const summary = claim.dates.length ? `${claim.dates.length} 天 · ${claim.dates[0]}${claim.dates.length > 1 ? ` 至 ${claim.dates[claim.dates.length - 1]}` : ''}` : '尚未选择日期';
  return `<div class="calendar-card">
    <div class="calendar-head"><button type="button" class="btn icon-only" data-action="calendar-prev">‹</button><strong>${first.getFullYear()} 年 ${first.getMonth() + 1} 月</strong><button type="button" class="btn icon-only" data-action="calendar-today">今天</button><button type="button" class="btn icon-only" data-action="calendar-next">›</button></div>
    <div class="calendar-grid" id="calendar-grid">
      ${['一','二','三','四','五','六','日'].map(day => `<div class="calendar-weekday">${day}</div>`).join('')}
      ${days.map(day => `<button type="button" class="calendar-day ${day.current ? '' : 'other'} ${day.selected ? 'selected' : ''}" data-calendar-day="${day.key}">${day.date.getDate()}</button>`).join('')}
    </div>
    <div class="date-summary">已选：${escapeHTML(summary)} · 点击或拖动扫选；往回扫可撤销</div>
  </div>`;
}

function renderTripEditor(claim) {
  const active = state.selectedExpenseType;
  return `<section class="card">
    <div class="card-header"><div><h2>出差费用明细</h2><p>类型可拖动排序；发票金额会同步更新交通和住宿费用</p></div><div class="header-actions"><button class="btn soft" data-action="add-expense">+ 再加一笔</button><button class="btn primary" data-action="import-trip">⇧ 导入</button></div></div>
    <div class="card-body">
      <div class="expense-types" id="expense-types">${C.TRIP_TYPES.map((kind, index) => `<button class="expense-tab ${active === kind ? 'active' : ''}" draggable="true" data-expense-tab="${kind}" data-index="${index}">${EXPENSE_ICONS[kind] || ''} ${kind}<span style="opacity:.55;margin-left:5px">${claim.expenses.filter(e => e.kind === kind).length}</span></button>`).join('')}</div>
      ${renderTripExpenseTable(claim, active)}
      <div class="table-footer"><span>当前类型 <strong>${escapeHTML(active)}</strong></span><span>${claim.expenses.filter(e => e.kind === active).length} 笔</span><span>报销总额 <strong>${C.formatMoney(C.claimTotal(claim))}</strong></span><span>发票 <strong>${C.formatMoney(C.invoiceTotal(claim))}</strong></span></div>
    </div>
  </section>`;
}

function renderTripExpenseTable(claim, kind) {
  let items = claim.expenses.filter(expense => expense.kind === kind);
  if (kind === '火车') items = [...items].sort((a, b) => (a.departureTime || '9999').localeCompare(b.departureTime || '9999'));
  if (!items.length) return `<div class="table-shell"><div class="empty-state" style="min-height:180px"><div><div class="empty-icon">${EXPENSE_ICONS[kind]}</div><h3>暂无${escapeHTML(kind)}费用</h3><p class="subtitle">点击“再加一笔”，或直接导入发票。</p></div></div></div>`;
  if (kind === '出差补助') return renderSubsidyTable(claim, items);
  if (kind === '火车' || kind === '飞机') return renderTransportTable(claim, items, kind);
  if (kind === '打车') return renderTaxiTable(claim, items);
  return renderHotelTable(claim, items);
}

function expenseField(expense, property, type = 'text', extra = '') {
  const value = expense[property] ?? '';
  return `<input class="cell-input" data-expense-id="${attr(expense.id)}" data-property="${property}" ${extra} value="${attr(value)}">`;
}

function personSelect(claim, expense) {
  return `<select class="cell-select" data-expense-id="${attr(expense.id)}" data-property="claimant"><option value="">未分配</option>${(claim.travelerNames || []).map(name => `<option ${expense.claimant === name ? 'selected' : ''}>${escapeHTML(name)}</option>`).join('')}</select>`;
}

function renderSubsidyTable(claim, items) {
  return `<div class="table-shell"><table class="data-table"><thead><tr><th class="no-sort">报销人</th><th class="no-sort">报销天数</th><th class="no-sort">补助单价</th><th class="no-sort">合计</th><th class="no-sort">备注</th><th class="no-sort">操作</th></tr></thead><tbody>
    ${items.map(expense => `<tr><td>${personSelect(claim, expense)}</td><td>${C.expenseDays(expense, claim)} 天</td><td><input class="cell-input cell-money" data-expense-money="${attr(expense.id)}" data-property="unitPrice" value="${C.inputMoney(expense.unitPrice)}"></td><td><strong>${C.formatMoney(C.expenseTotal(expense, claim))}</strong></td><td>${expenseField(expense, 'note')}</td><td>${rowActions(expense, false)}</td></tr>`).join('')}
  </tbody></table></div>`;
}

function renderTransportTable(claim, items, kind) {
  return `<div class="table-shell"><table class="data-table"><thead><tr><th class="no-sort">出发日期</th><th class="no-sort">出发地</th><th class="no-sort">到达日期</th><th class="no-sort">目的地</th><th class="no-sort">报销人</th><th class="no-sort">发票</th><th class="no-sort">发票号码</th><th class="no-sort">发票金额</th><th class="no-sort">备注</th><th class="no-sort">操作</th></tr></thead><tbody>
    ${items.map(expense => { const invoice = expense.invoices[0]; return `<tr>
      <td><input class="cell-input" type="date" data-expense-id="${attr(expense.id)}" data-property="departureTime" value="${attr((expense.departureTime || '').slice(0,10))}"></td>
      <td>${expenseField(expense, 'origin', 'text', 'placeholder="出发地"')}</td>
      <td><input class="cell-input" type="date" data-expense-id="${attr(expense.id)}" data-property="arrivalTime" value="${attr((expense.arrivalTime || expense.departureTime || '').slice(0,10))}"></td>
      <td>${expenseField(expense, 'destination', 'text', 'placeholder="目的地"')}</td><td>${personSelect(claim, expense)}</td>
      <td>${invoice ? fileChip(invoice, ['invoice', expense.id, invoice.id]) : `<button class="row-action" data-action="upload-expense" data-expense-id="${attr(expense.id)}" title="上传发票">⇧</button>`}</td>
      <td>${invoice ? `<input class="cell-input" data-invoice-id="${attr(invoice.id)}" data-invoice-property="number" value="${attr(invoice.number || '')}">` : '—'}</td>
      <td>${invoice ? `<input class="cell-input cell-money" inputmode="decimal" data-invoice-money="${attr(invoice.id)}" value="${C.inputMoney(invoice.amount)}">` : `<input class="cell-input cell-money" data-expense-money="${attr(expense.id)}" data-property="unitPrice" value="${C.inputMoney(expense.unitPrice)}">`}</td>
      <td>${expenseField(expense, 'note')}</td><td>${rowActions(expense, false)}</td></tr>`; }).join('')}
  </tbody></table></div>`;
}

function renderTaxiTable(claim, items) {
  return `<div class="table-shell"><table class="data-table"><thead><tr><th class="no-sort">日期</th><th class="no-sort">报销人</th><th class="no-sort">发票</th><th class="no-sort">行程单</th><th class="no-sort">发票号码</th><th class="no-sort">发票金额</th><th class="no-sort">备注</th><th class="no-sort">操作</th></tr></thead><tbody>
    ${items.map(expense => { const invoice = expense.invoices[0], itinerary = expense.itineraries?.[0]; return `<tr>
      <td><input class="cell-input" type="date" data-expense-id="${attr(expense.id)}" data-property="date" value="${attr((expense.dates || claim.dates || [])[0] || '')}"></td><td>${personSelect(claim, expense)}</td>
      <td>${invoice ? fileChip(invoice, ['invoice', expense.id, invoice.id]) : `<button class="row-action" data-action="upload-expense" data-expense-id="${attr(expense.id)}" title="上传发票">⇧</button>`}</td>
      <td>${itinerary ? fileChip(itinerary, ['itinerary', expense.id, itinerary.id]) : `<button class="row-action" data-action="upload-itinerary" data-expense-id="${attr(expense.id)}" title="上传行程单">⇧</button>`}</td>
      <td>${invoice ? `<input class="cell-input" data-invoice-id="${attr(invoice.id)}" data-invoice-property="number" value="${attr(invoice.number || '')}">` : '—'}</td>
      <td>${invoice ? `<input class="cell-input cell-money" inputmode="decimal" data-invoice-money="${attr(invoice.id)}" value="${C.inputMoney(invoice.amount)}">` : `<input class="cell-input cell-money" data-expense-money="${attr(expense.id)}" data-property="unitPrice" value="${C.inputMoney(expense.unitPrice)}">`}</td>
      <td>${expenseField(expense, 'note')}</td><td>${rowActions(expense, true)}</td></tr>`; }).join('')}
  </tbody></table></div>`;
}

function renderHotelTable(claim, items) {
  return `<div class="table-shell"><table class="data-table"><thead><tr><th class="no-sort">报销人</th><th class="no-sort">入住晚数</th><th class="no-sort">住宿总价</th><th class="no-sort">发票</th><th class="no-sort">发票号码</th><th class="no-sort">备注</th><th class="no-sort">操作</th></tr></thead><tbody>
    ${items.map(expense => { const invoice = expense.invoices[0]; const amount = expense.totalAmount != null ? expense.totalAmount : C.expenseTotal(expense, claim); return `<tr><td>${personSelect(claim, expense)}</td><td>${C.expenseDays(expense, claim)} 晚</td>
      <td><input class="cell-input cell-money" data-expense-money="${attr(expense.id)}" data-property="totalAmount" value="${C.inputMoney(amount)}"></td>
      <td>${invoice ? fileChip(invoice, ['invoice', expense.id, invoice.id]) : `<button class="row-action" data-action="upload-expense" data-expense-id="${attr(expense.id)}" title="上传发票">⇧</button>`}</td>
      <td>${invoice ? `<input class="cell-input" data-invoice-id="${attr(invoice.id)}" data-invoice-property="number" value="${attr(invoice.number || '')}">` : '—'}</td>
      <td>${expenseField(expense, 'note')}</td><td>${rowActions(expense, false)}</td></tr>`; }).join('')}
  </tbody></table></div>`;
}

function rowActions(expense, itinerary) {
  return `<div class="row-actions">
    <button class="row-action" data-action="copy-expense" data-expense-id="${attr(expense.id)}" title="复制行">⧉</button>
    <button class="row-action" data-action="upload-expense" data-expense-id="${attr(expense.id)}" title="上传发票">⇧</button>
    ${itinerary ? `<button class="row-action" data-action="upload-itinerary" data-expense-id="${attr(expense.id)}" title="上传行程单">行</button>` : ''}
    <button class="row-action danger" data-action="delete-expense" data-expense-id="${attr(expense.id)}" title="删除行">×</button>
  </div>`;
}

function fileChip(file, dataset) {
  return `<button class="file-chip" data-action="preview-file" data-scope="${attr(dataset[0])}" data-expense-id="${attr(dataset[1])}" data-file-id="${attr(dataset[2])}" title="${attr(file.name)}"><span>▤</span><span>${escapeHTML(file.name)}</span></button>`;
}

function renderSimpleEditor(claim) {
  const invoiceTotal = C.invoiceTotal(claim), total = C.claimTotal(claim);
  return `<section class="card">
    <div class="card-header"><div><h2>${claim.kind === '餐补' ? '餐补计算' : '补贴信息'}</h2><p>${claim.kind === '餐补' ? '报销总额按日期天数 × 每日单价计算' : '补贴总额单独填写，发票金额独立统计'}</p></div><button class="btn primary" data-action="import-ledger">⇧ 导入</button></div>
    <div class="card-body"><div class="stats-grid" style="grid-template-columns:repeat(3,1fr);margin:4px 0 0">
      <div class="stat-card"><div class="label">报销总额</div><div class="value" style="font-size:20px">${C.formatMoney(total)}</div></div>
      <div class="stat-card"><div class="label">发票总额</div><div class="value" style="font-size:20px">${C.formatMoney(invoiceTotal)}</div></div>
      <div class="stat-card"><div class="label">发票数量</div><div class="value" style="font-size:20px">${C.invoiceCount(claim)} 份</div></div>
    </div></div>
  </section>`;
}

function sortedLedgerRows(claim) {
  let rows = C.ledgerRows(claim, state.ledgerSort.ascending == null);
  if (!state.ledgerSort.column || state.ledgerSort.ascending == null) return rows;
  const getValue = row => {
    switch (state.ledgerSort.column) {
      case 'date': return row.date || '';
      case 'person': return row.claimant || '';
      case 'number': return row.invoice?.number || '';
      case 'invoice': return row.invoice?.name || '';
      case 'amount': return Number(row.invoice?.amount || 0);
      case 'reimbursement': return Number(row.reimbursementAmount || 0);
      case 'detail': return row.detail || '';
      case 'purpose': return row.purpose || '';
      default: return '';
    }
  };
  return [...rows].sort((a, b) => {
    const av = getValue(a), bv = getValue(b); const result = typeof av === 'number' ? av - bv : String(av).localeCompare(String(bv), 'zh-CN');
    return state.ledgerSort.ascending ? result : -result;
  });
}

function ledgerHeader(id, title) {
  const active = state.ledgerSort.column === id;
  const arrow = active ? (state.ledgerSort.ascending === true ? '▲' : state.ledgerSort.ascending === false ? '▼' : '↕') : '';
  return `<th data-action="ledger-sort" data-column="${id}">${title}<span style="opacity:${active ? .8 : .25};font-size:8px;margin-left:3px">${arrow || '↕'}</span></th>`;
}

function renderLedgerCard(claim) {
  const rows = sortedLedgerRows(claim);
  return `<section class="card" id="ledger-card">
    <div class="card-header"><div><h2>报销清单</h2><p>${claim.kind === '出差' ? '默认按明细类型排序，可在表头切换排序' : '发票与费用逐行核对，报销总额与发票金额独立统计'}</p></div><div class="ledger-tools"><button class="btn" data-action="export-ledger">⇩ 导出</button><button class="btn primary" data-action="import-ledger">⇧ 导入</button></div></div>
    <div class="card-body">${rows.length ? `<div class="table-shell"><table class="data-table" style="min-width:1120px"><thead><tr>${ledgerHeader('sequence', '序号')}${ledgerHeader('date', '日期')}${ledgerHeader('person', '姓名')}${ledgerHeader('number', '发票号码')}${ledgerHeader('invoice', '发票')}${ledgerHeader('amount', '发票金额')}${ledgerHeader('reimbursement', '报销单金额')}${ledgerHeader('detail', '明细')}${ledgerHeader('purpose', '用途')}<th class="no-sort">操作</th></tr></thead><tbody>
      ${rows.map((row, index) => `<tr>
        <td>${index + 1}</td><td><input class="cell-input" type="date" data-ledger-id="${attr(row.id)}" data-ledger-property="date" value="${attr(row.date || '')}"></td>
        <td><select class="cell-select" data-ledger-id="${attr(row.id)}" data-ledger-property="claimant"><option value="">未填写</option>${C.uniqueNames([...(claim.travelerNames || []), row.claimant].filter(Boolean)).map(name => `<option ${row.claimant === name ? 'selected' : ''}>${escapeHTML(name)}</option>`).join('')}</select></td>
        <td><input class="cell-input" data-invoice-id="${attr(row.invoice?.id)}" data-invoice-property="number" value="${attr(row.invoice?.number || '')}"></td>
        <td>${row.invoice ? fileChip(row.invoice, ['invoice', row.expenseID, row.invoice.id]) : '—'}</td>
        <td><input class="cell-input cell-money" inputmode="decimal" data-invoice-money="${attr(row.invoice?.id)}" value="${C.inputMoney(row.invoice?.amount || 0)}"></td>
        <td><input class="cell-input cell-money" inputmode="decimal" data-ledger-money="${attr(row.id)}" value="${C.inputMoney(row.reimbursementAmount || 0)}"></td>
        <td><input class="cell-input" data-ledger-id="${attr(row.id)}" data-ledger-property="detail" value="${attr(row.detail || '')}"></td>
        <td><span title="${attr(row.purpose)}">${escapeHTML(row.purpose || '未填写')}</span></td>
        <td><div class="row-actions"><button class="row-action" data-action="copy-ledger" data-ledger-id="${attr(row.id)}" title="复制行">⧉</button><button class="row-action" data-action="replace-ledger" data-ledger-id="${attr(row.id)}" title="上传发票">⇧</button><button class="row-action danger" data-action="delete-ledger" data-ledger-id="${attr(row.id)}" title="删除行">×</button></div></td>
      </tr>`).join('')}</tbody></table></div>` : `<div class="empty-state" style="min-height:170px"><div><div class="empty-icon">▤</div><h3>暂无发票</h3><p class="subtitle">点击右上角“导入”，支持一次选择多个 PDF。</p></div></div>`}
      <div class="table-footer"><span>${rows.length} 行 · ${C.invoiceCount(claim)} 份发票</span><span>票面合计 <strong>${C.formatMoney(C.invoiceTotal(claim))}</strong></span><span>报销单金额合计 <strong>${C.formatMoney(rows.reduce((sum, row) => sum + Number(row.reimbursementAmount || 0), 0))}</strong></span><span>差额 <strong>${C.formatMoney(C.difference(claim))}</strong></span></div>
    </div>
  </section>`;
}

function renderPersonDetailCard(claim) {
  const names = C.personNames(claim).filter(Boolean);
  if (!names.length) names.push('未分配');
  if (!names.includes(state.personTab) && state.personTab !== '总览') state.personTab = '总览';
  const active = state.personTab;
  const person = active === '总览' ? null : active;
  return `<section class="card"><div class="card-header"><div><h2>个人明细</h2><p>总览不混入个人清单，切换标签查看每位出差人的费用</p></div></div><div class="card-body">
    <div class="summary-tabs"><button class="summary-tab ${active === '总览' ? 'active' : ''}" data-action="person-tab" data-person="总览">总览</button>${names.map(name => `<button class="summary-tab ${active === name ? 'active' : ''}" data-action="person-tab" data-person="${attr(name)}">${escapeHTML(name)}</button>`).join('')}</div>
    <div class="summary-paper">${escapeHTML(C.summaryText(claim, person))}</div>
  </div></section>`;
}

function renderSettings() {
  const path = state.dataPath || {};
  document.getElementById('main-content').innerHTML = `${pageHeader({ eyebrow: 'SETTINGS', title: '设置', subtitle: `Reimbur Windows ${state.appVersion}` })}
    <div class="settings-layout">
      <section class="card"><div class="card-header"><div><h2>默认值</h2><p>仅用于新建记录，不修改已有记录</p></div></div><div class="card-body"><div class="settings-grid">
        ${settingField('报销人', 'traveler', '多个姓名用逗号分隔')}${settingField('部门', 'department', '默认部门')}${settingField('出差事由', 'tripPurpose', '默认出差事由')}${settingField('出差补助 / 人天', 'subsidyPrice', '例如 50.00', 'money')}${settingField('餐补 / 天', 'mealPrice', '例如 30.00', 'money')}${settingField('左下角文字', 'caption', '最多 14 个字')}
      </div></div></section>
      <section class="card"><div class="card-header"><div><h2>附件命名</h2><p>上传后自动重命名，重复时自动添加 _1、_2 等后缀</p></div></div><div class="card-body"><div class="settings-grid">${settingField('发票命名格式', 'invoiceFormat', '{报销人}{发票号码}')}${settingField('行程单命名格式', 'itineraryFormat', '{报销人}{行程单号}')}</div><div class="settings-help" style="margin-top:10px">可用字段：{报销人}、{发票号码}、{行程单号}、{报销名称}、{费用类型}、{原文件名}、{日期}</div></div></section>
      <section class="card"><div class="card-header"><div><h2>数据与存储</h2><p>SQLite 本地数据库；附件、行程单和报销单保留独立副本</p></div></div><div class="card-body"><div class="field"><label>数据目录</label><div class="mono">${escapeHTML(path.root || '')}</div></div><div class="field" style="margin-top:10px"><label>数据库文件</label><div class="mono">${escapeHTML(path.database || '')}</div></div><div class="header-actions" style="margin-top:12px"><button class="btn" data-action="copy-data-path">⧉ 复制路径</button><button class="btn" data-action="open-data-dir">打开数据目录</button><button class="btn" data-action="export-all-invoices">导出发票</button><button class="btn primary" data-action="print-all">打印全部发票</button></div></div></section>
      <section class="card"><div class="card-header"><div><h2>关于</h2><p>本机离线使用，不上传任何报销数据</p></div></div><div class="card-body"><div style="display:flex;justify-content:space-between;gap:12px;align-items:center"><div><strong>Reimbur · 轻记报销</strong><p class="settings-help">Windows 版 ${escapeHTML(state.appVersion)} · Electron / SQLite / PDF.js</p></div><button class="btn soft" data-action="github">GitHub · SherlockerSun/Reimbur</button></div></div></section>
    </div>`;
}
function settingField(label, key, placeholder, type = '') {
  return `<div class="field"><label>${escapeHTML(label)}</label><input ${type === 'money' ? 'inputmode="decimal"' : ''} data-setting="${key}" value="${attr(state.settings[key] || '')}" placeholder="${attr(placeholder)}"></div>`;
}

function bindClaimViewEvents() {
  const claim = getClaim(); if (!claim) return;
  const grid = document.getElementById('calendar-grid');
  if (grid) {
    grid.addEventListener('pointerdown', beginCalendarSweep);
    grid.addEventListener('pointerover', moveCalendarSweep);
  }
  const traveler = document.getElementById('traveler-input');
  if (traveler) {
    traveler.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ',') { event.preventDefault(); commitTravelerInput(); } });
    traveler.addEventListener('blur', commitTravelerInput);
  }
  document.querySelectorAll('[data-expense-tab]').forEach(tab => {
    tab.addEventListener('dragstart', event => { event.dataTransfer.setData('text/plain', tab.dataset.expenseTab); tab.classList.add('dragging'); });
    tab.addEventListener('dragend', () => tab.classList.remove('dragging'));
    tab.addEventListener('dragover', event => event.preventDefault());
    tab.addEventListener('drop', event => { event.preventDefault(); reorderExpenseType(event.dataTransfer.getData('text/plain'), tab.dataset.expenseTab); });
  });
}

async function handleClick(event) {
  const actionElement = event.target.closest('[data-action]');
  if (actionElement) {
    const action = actionElement.dataset.action;
    if (action === 'open-record') {
      if (event.target.matches('[data-action="check-record"]')) return;
      closeContextMenu();
      state.selectedId = actionElement.dataset.id; state.view = 'claim';
      const claim = getClaim();
      state.kindFilter = claim.kind;
      state.selectedExpenseType = claim.kind === '出差' ? (state.selectedExpenseType || '出差补助') : claim.kind === '餐补' ? '餐补' : '补助';
      const date = C.reimbursementDates(claim)[0] || C.dayKey(claim.createdAt);
      state.calendarMonth = new Date(`${date}T12:00:00`);
      renderAll(); return;
    }
    if (action === 'check-record') {
      event.stopPropagation();
      const id = actionElement.dataset.id;
      actionElement.checked ? state.checked.add(id) : state.checked.delete(id);
      return;
    }
    if (action === 'new-claim') return createClaim(state.kindFilter);
    if (action === 'create-kind') return createClaim(actionElement.dataset.kind);
    if (action === 'close-modal') return closeModal();
    if (action === 'toggle-records') { state.recordsCollapsed = !state.recordsCollapsed; renderAll(); return; }
    if (action === 'toggle-batch') { state.batch = !state.batch; state.checked.clear(); renderSidebar(); return; }
    if (action === 'delete-checked') return deleteChecked();
    if (action === 'select-all') return;
    if (action === 'show-all-trip') { showKind('出差'); return; }
    if (action === 'settings') { showSettings(); return; }
    if (action === 'github') { API.openExternal('https://github.com/SherlockerSun/Reimbur'); return; }
    if (action === 'copy-data-path') { API.copyText(state.dataPath?.root || ''); showToast('数据路径已复制'); return; }
    if (action === 'open-data-dir') { API.openDataDir(); return; }
    if (action === 'calendar-prev' || action === 'calendar-next') {
      const offset = action === 'calendar-prev' ? -1 : 1;
      state.calendarMonth = new Date(state.calendarMonth.getFullYear(), state.calendarMonth.getMonth() + offset, 1);
      renderClaim(); return;
    }
    if (action === 'calendar-today') { state.calendarMonth = new Date(); renderClaim(); return; }
    if (action === 'remove-traveler') { removeTraveler(actionElement.dataset.name); return; }
    if (action === 'add-expense') { addTripExpenses(); return; }
    if (action === 'import-trip') { return importTripBatch(); }
    if (action === 'import-ledger') { return importIntoLedger(); }
    if (action === 'upload-expense') { return importIntoExpense(actionElement.dataset.expenseId, 'invoice'); }
    if (action === 'upload-itinerary') { return importIntoExpense(actionElement.dataset.expenseId, 'itinerary'); }
    if (action === 'preview-file') { return previewFile(actionElement.dataset.scope, actionElement.dataset.expenseId, actionElement.dataset.fileId); }
    if (action === 'delete-expense') { return deleteExpense(actionElement.dataset.expenseId); }
    if (action === 'copy-expense') { return copyExpense(actionElement.dataset.expenseId); }
    if (action === 'delete-ledger') { return deleteLedgerRow(actionElement.dataset.ledgerId); }
    if (action === 'copy-ledger') { return copyLedgerRow(actionElement.dataset.ledgerId); }
    if (action === 'replace-ledger') { return replaceLedgerRow(actionElement.dataset.ledgerId); }
    if (action === 'preview-summary') { return openSummaryModal(); }
    if (action === 'preview-form') { return openFormPreview(); }
    if (action === 'upload-cover') { return importCover(); }
    if (action === 'copy-preview') { if (previewState) { try { await API.copyAttachmentFile(previewState.entries[previewState.index].file.storedName); showToast('附件已复制，可直接粘贴'); } catch (error) { showError(error); } } return; }
    if (action === 'person-tab') { state.personTab = actionElement.dataset.person; renderClaim(); return; }
    if (action === 'ledger-sort') { return toggleLedgerSort(actionElement.dataset.column); }
    if (action === 'export-ledger') { return exportLedger(); }
    if (action === 'export-invoices') { return exportInvoices(getClaim()); }
    if (action === 'export-print') { return exportPrint(getClaim()); }
    if (action === 'export-all-invoices') { return exportInvoicesAll(); }
    if (action === 'print-all') { return exportPrintAll(); }
    if (action === 'copy-summary') { API.copyText(actionElement.dataset.text || ''); showToast('报销清单已复制'); return; }
    if (action === 'download-preview') { downloadPreview(); return; }
    if (action === 'preview-previous') { navigatePreview(-1); return; }
    if (action === 'preview-next') { navigatePreview(1); return; }
  }
  const nav = event.target.closest('.nav-item');
  if (nav) {
    if (nav.dataset.view === 'home') showHome();
    if (nav.dataset.kind) showKind(nav.dataset.kind);
    return;
  }
  if (event.target.closest('#settings-button')) { showSettings(); return; }
  if (event.target.closest('#collapse-button')) { state.menuCollapsed = !state.menuCollapsed; renderAll(); return; }
  if (event.target.closest('#records-toggle')) { state.recordsCollapsed = !state.recordsCollapsed; renderAll(); return; }
  if (event.target.closest('#batch-toggle')) { state.batch = !state.batch; state.checked.clear(); renderSidebar(); return; }
  const tab = event.target.closest('[data-expense-tab]');
  if (tab) { state.selectedExpenseType = tab.dataset.expenseTab; renderClaim(); }
}

function handleInput(event) {
  const element = event.target;
  if (element.id === 'traveler-input' || element.id === 'record-search' || element.id === 'home-period') return;
  if (element.dataset.field === 'title') {
    const claim = getClaim(); if (!claim) return;
    claim.title = element.value;
    const record = document.querySelector(`.record-item[data-id="${CSS.escape(claim.id)}"] .record-title`); if (record) record.textContent = claim.title;
    queueSave();
  }
}

function handleChange(event) {
  const element = event.target;
  if (element.matches('[data-action="select-all"]')) return;
  if (element.dataset.field) {
    const claim = getClaim(); if (!claim) return;
    claim[element.dataset.field] = element.value;
    queueSave({ sidebar: true, main: true }); return;
  }
  if (element.dataset.setting) {
    const value = element.dataset.setting === 'caption' ? element.value.slice(0, 14) : element.value;
    state.settings[element.dataset.setting] = value; element.value = value; saveSettings(); renderSidebar(); return;
  }
  if (element.dataset.expenseId && element.dataset.property) {
    const claim = getClaim(), expense = claim?.expenses.find(item => item.id === element.dataset.expenseId); if (!expense) return;
    if (element.dataset.property === 'arrivalTime' && !element.value) expense.arrivalTime = expense.departureTime || '';
    else expense[element.dataset.property] = element.value;
    if (element.dataset.property === 'date') expense.dates = element.value ? [element.value] : null;
    queueSave({ main: true }); return;
  }
  if (element.dataset.expenseMoney) {
    const claim = getClaim(), expense = claim?.expenses.find(item => item.id === element.dataset.expenseMoney); if (!expense) return;
    const cents = C.parseCents(element.value);
    if (cents == null) { showToast('请输入有效金额', true); element.value = C.inputMoney(expense[element.dataset.property] || 0); return; }
    expense[element.dataset.property] = cents;
    if (element.dataset.property === 'totalAmount') { expense.totalAmount = cents; expense.invoiceTotalLinked = false; }
    queueSave({ main: true }); return;
  }
  if (element.dataset.invoiceId && element.dataset.invoiceProperty) {
    const found = findInvoice(element.dataset.invoiceId);
    if (found) { found.invoice[element.dataset.invoiceProperty] = element.value; queueSave({ main: true }); }
    return;
  }
  if (element.dataset.invoiceMoney) {
    const found = findInvoice(element.dataset.invoiceMoney); const cents = C.parseCents(element.value);
    if (!found) return;
    if (cents == null) { showToast('请输入有效金额', true); element.value = C.inputMoney(found.invoice.amount); return; }
    found.invoice.amount = cents;
    if (['火车', '飞机', '打车'].includes(found.expense.kind)) { found.expense.unitPrice = cents; found.expense.totalAmount = cents; }
    if (found.expense.kind === '住宿') found.expense.totalAmount = cents;
    queueSave({ main: true }); return;
  }
  if (element.dataset.ledgerId && element.dataset.ledgerProperty) {
    const claim = getClaim(), entry = claim?.invoiceLedgerEntries?.find(item => item.id === element.dataset.ledgerId); if (!entry) return;
    entry[element.dataset.ledgerProperty] = element.value; queueSave({ main: true }); return;
  }
  if (element.dataset.ledgerMoney) {
    const claim = getClaim(), entry = claim?.invoiceLedgerEntries?.find(item => item.id === element.dataset.ledgerMoney);
    const cents = C.parseCents(element.value); if (!entry) return;
    if (cents == null) { showToast('请输入有效金额', true); element.value = C.inputMoney(entry.reimbursementAmount); return; }
    entry.reimbursementAmount = cents; queueSave({ main: true }); return;
  }
  if (element.id === 'select-all') {
    const records = filteredRecords();
    if (element.checked) records.forEach(record => state.checked.add(record.id)); else state.checked.clear();
    renderSidebar();
  }
}

function handleKeydown(event) {
  if (event.target.matches('.record-item') && (event.key === 'Enter' || event.key === ' ')) {
    event.target.click();
  }
  if (event.target.id === 'traveler-input' && event.key === 'Enter') {
    event.preventDefault(); commitTravelerInput();
  }
}

function handleContextMenu(event) {
  const record = event.target.closest('.record-item');
  const file = event.target.closest('[data-action="preview-file"]');
  if (!record && !file) return;
  event.preventDefault(); closeContextMenu();
  if (record) {
    const id = record.dataset.id, claim = state.claims.find(item => item.id === id);
    contextMenu = document.createElement('div'); contextMenu.className = 'context-menu';
    contextMenu.innerHTML = `<button data-context="open">打开</button><button data-context="rename">重命名</button><button data-context="preview">预览清单</button><button data-context="copy">复制清单</button>${C.STATUSES.map(status => `<button data-context="status" data-value="${status}">状态：${status}</button>`).join('')}<button class="danger" data-context="delete">删除</button>`;
    contextMenu.addEventListener('click', async click => {
      const item = click.target.closest('button'); if (!item) return;
      const action = item.dataset.context;
      if (action === 'open') { closeContextMenu(); document.querySelector(`.record-item[data-id="${CSS.escape(id)}"]`)?.click(); }
      if (action === 'rename') { closeContextMenu(); renameRecord(id); }
      if (action === 'preview') { closeContextMenu(); state.selectedId = id; openSummaryModal(); }
      if (action === 'copy') { closeContextMenu(); API.copyText(C.summaryText(claim)); showToast('报销清单已复制'); }
      if (action === 'status') { claim.savedStatus = item.dataset.value; C.normalize(claim); await API.saveClaim(claim); closeContextMenu(); renderAll(); }
      if (action === 'delete') { closeContextMenu(); await deleteIds([id]); }
    });
    document.body.appendChild(contextMenu); positionContextMenu(event);
  } else if (file) {
    contextMenu = document.createElement('div'); contextMenu.className = 'context-menu';
    contextMenu.innerHTML = '<button data-context="open">打开预览</button><button data-context="rename">重命名</button><button data-context="copy">复制文件</button><button data-context="download">下载文件</button><button class="danger" data-context="delete">删除文件</button>';
    contextMenu.addEventListener('click', async click => {
      const item = click.target.closest('button'); if (!item) return; const action = item.dataset.context; closeContextMenu();
      const found = findAttachmentByDOM(file);
      if (!found) return;
      if (action === 'open') previewFile(file.dataset.scope, file.dataset.expenseId, file.dataset.fileId);
      if (action === 'rename') renameAttachment(found);
      if (action === 'copy') copyAttachment(found);
      if (action === 'download') downloadAttachment(found.file);
      if (action === 'delete') deleteAttachment(found);
    });
    document.body.appendChild(contextMenu); positionContextMenu(event);
  }
}
function positionContextMenu(event) {
  if (!contextMenu) return;
  const left = Math.min(event.clientX, innerWidth - contextMenu.offsetWidth - 8), top = Math.min(event.clientY, innerHeight - contextMenu.offsetHeight - 8);
  contextMenu.style.left = `${Math.max(6, left)}px`; contextMenu.style.top = `${Math.max(6, top)}px`;
}
function closeContextMenu() { contextMenu?.remove(); contextMenu = null; }

function commitTravelerInput() {
  const input = document.getElementById('traveler-input'), claim = getClaim();
  if (!input || !claim) return;
  const names = input.value.split(/[，,、\s]+/).map(value => value.trim()).filter(Boolean);
  if (!names.length) return;
  claim.travelerNames = C.uniqueNames([...(claim.travelerNames || []), ...names]);
  claim.travelers = claim.travelerNames.length;
  syncPeople(claim);
  input.value = '';
  queueSave(); renderClaim();
}
function removeTraveler(name) {
  const claim = getClaim(); if (!claim) return;
  claim.travelerNames = (claim.travelerNames || []).filter(value => value !== name);
  claim.travelers = claim.travelerNames.length;
  claim.expenses = claim.expenses.filter(expense => !(expense.kind === '出差补助' && expense.claimant === name));
  for (const expense of claim.expenses) if (expense.claimant === name) expense.claimant = claim.travelerNames[0] || null;
  syncPeople(claim); queueSave(); renderClaim();
}

function syncPeople(claim) {
  const names = claim.travelerNames || [];
  if (!names.length) return;
  for (const expense of claim.expenses) {
    if (expense.claimant === null || expense.claimant === undefined) expense.claimant = names[0];
  }
  const subsidies = claim.expenses.filter(expense => expense.kind === '出差补助');
  const template = subsidies[0];
  if (template) for (const name of names) {
    if (!subsidies.some(expense => expense.claimant === name)) {
      const row = C.makeExpense('出差补助', template.unitPrice, name); row.dates = template.dates; row.note = template.note; claim.expenses.push(row);
    }
  }
}

function addTripExpenses() {
  const claim = getClaim(); if (!claim) return;
  const kind = state.selectedExpenseType;
  if (kind === '出差补助') {
    const names = claim.travelerNames?.length ? claim.travelerNames : [null];
    const price = C.parseCents(state.settings.subsidyPrice) ?? 0;
    names.forEach(name => claim.expenses.push(C.makeExpense(kind, price, name)));
  } else {
    claim.expenses.push(C.makeExpense(kind, '0', claim.travelerNames?.[0] || null));
  }
  queueSave(); renderClaim();
}

function reorderExpenseType(source, target) {
  if (!source || !target || source === target) return;
  const claim = getClaim(); if (!claim) return;
  const order = C.expenseTypeOrder(claim).filter(kind => kind !== source);
  order.splice(order.indexOf(target), 0, source);
  claim.expenseOrder = order; queueSave(); renderClaim();
}

function beginCalendarSweep(event) {
  const day = event.target.closest('[data-calendar-day]'); if (!day) return;
  event.preventDefault();
  const claim = getClaim(); if (!claim) return;
  calendarSweep = { start: day.dataset.calendarDay, initial: new Set(claim.dates || []), mode: (claim.dates || []).includes(day.dataset.calendarDay) ? 'remove' : 'add' };
  applyCalendarSweep(day.dataset.calendarDay);
}
let calendarSweep = null;
function moveCalendarSweep(event) {
  if (!calendarSweep) return;
  const day = event.target.closest('[data-calendar-day]'); if (day) applyCalendarSweep(day.dataset.calendarDay);
}
function applyCalendarSweep(current) {
  const claim = getClaim(); if (!claim || !calendarSweep) return;
  const [start, end] = [calendarSweep.start, current].sort();
  const range = datesInRange(start, end);
  claim.dates = calendarSweep.mode === 'add' ? [...new Set([...calendarSweep.initial, ...range])].sort() : [...calendarSweep.initial].filter(date => !range.includes(date)).sort();
  document.querySelectorAll('[data-calendar-day]').forEach(button => button.classList.toggle('selected', claim.dates.includes(button.dataset.calendarDay)));
  const summary = document.querySelector('.date-summary');
  if (summary) summary.textContent = `已选：${claim.dates.length} 天${claim.dates.length ? ` · ${claim.dates[0]}${claim.dates.length > 1 ? ` 至 ${claim.dates[claim.dates.length - 1]}` : ''}` : ''} · 点击或拖动扫选；往回扫可撤销`;
}
function finishCalendarSweep() {
  if (!calendarSweep) return;
  calendarSweep = null; queueSave(); renderClaim();
}
function datesInRange(start, end) {
  const result = [], date = new Date(`${start}T12:00:00`), last = new Date(`${end}T12:00:00`);
  while (date <= last) { result.push(C.dayKey(date)); date.setDate(date.getDate() + 1); }
  return result;
}

async function importTripBatch() {
  const claim = getClaim(); if (!claim) return;
  try {
    const raw = await API.importAttachments({ title: `导入${state.selectedExpenseType}` });
    if (!raw.length) return;
    const files = await prepareImportedFiles(raw, state.selectedExpenseType);
    await attachTripFiles(claim, files, state.selectedExpenseType);
    queueSave(); renderClaim(); showToast(`已导入 ${files.length} 个文件`);
  } catch (error) { showError(error); }
}

async function importIntoExpense(expenseId, requestedRole) {
  const claim = getClaim(), expense = claim?.expenses.find(item => item.id === expenseId); if (!expense) return;
  try {
    const raw = await API.importAttachments({ title: requestedRole === 'itinerary' ? '导入行程单' : '导入发票', itineraryOnly: requestedRole === 'itinerary' });
    if (!raw.length) return;
    const files = await prepareImportedFiles(raw, expense.kind);
    for (const file of files) {
      const role = requestedRole === 'itinerary' ? 'itinerary' : file.role;
      if (role === 'itinerary') {
        expense.itineraries = expense.itineraries || []; expense.itineraries.push(file.attachment);
      } else {
        expense.invoices.push(file.attachment);
        applyRecognition(expense, file);
      }
    }
    C.syncLedger(claim); queueSave(); renderClaim(); showToast('附件已导入');
  } catch (error) { showError(error); }
}

async function importIntoLedger() {
  const claim = getClaim(); if (!claim) return;
  if (claim.kind === '出差') return importTripBatch();
  try {
    const raw = await API.importAttachments({ title: '导入发票' });
    if (!raw.length) return;
    const files = await prepareImportedFiles(raw, claim.kind);
    const expense = claim.expenses[0] || C.makeExpense(claim.kind, '0', claim.travelerNames?.[0] || null);
    if (!claim.expenses[0]) claim.expenses.push(expense);
    for (const file of files) { expense.invoices.push(file.attachment); applyRecognition(expense, file); }
    C.syncLedger(claim); queueSave(); renderClaim(); showToast(`已导入 ${files.length} 份发票`);
  } catch (error) { showError(error); }
}

async function prepareImportedFiles(raw, kind) {
  const claim = getClaim();
  const usedNames = new Set(claim.expenses.flatMap(expense => [...(expense.invoices || []), ...(expense.itineraries || [])]).map(file => String(file.name).toLowerCase()));
  const result = [];
  for (const attachment of raw) {
    const metadata = await inspectAttachment(attachment, kind);
    Object.assign(attachment, metadata);
    const placeholderExpense = C.makeExpense(kind, '0', claim.travelerNames?.[0] || null);
    attachment.name = C.uniqueFilename(C.attachFilename(attachment, claim, placeholderExpense, metadata.role, state.settings), usedNames);
    result.push({ attachment, ...metadata });
  }
  return result;
}

async function inspectAttachment(attachment, kind) {
  const result = { role: 'invoice', number: null, amount: 0, pageCount: 1, route: null, date: null };
  if (attachment.mime !== 'application/pdf' && !String(attachment.name).toLowerCase().endsWith('.pdf')) {
    if (kind === '打车' && /行程|行程单/i.test(attachment.name)) result.role = 'itinerary';
    return result;
  }
  try {
    const data = await API.readAttachment(attachment.storedName);
    const bytes = data.data instanceof Uint8Array ? data.data : new Uint8Array(data.data);
    if (!window.pdfjsLib) return result;
    window.pdfjsLib.GlobalWorkerOptions.workerSrc = new URL('vendor/pdf.worker.min.js', location.href).href;
    const pdf = await window.pdfjsLib.getDocument({ data: bytes }).promise;
    result.pageCount = pdf.numPages;
    let text = '';
    for (let pageNumber = 1; pageNumber <= Math.min(2, pdf.numPages); pageNumber++) {
      const page = await pdf.getPage(pageNumber), content = await page.getTextContent();
      text += '\n' + content.items.map(item => item.str || '').join(' ');
    }
    const compact = text.replace(/\s+/g, '');
    if (kind === '打车') {
      const invoiceAt = compact.search(/电子(?:普通|专用)?发票|增值税.*发票/);
      const itineraryAt = compact.search(/行程单|行程明细|行程证明|用车明细/);
      result.role = itineraryAt >= 0 && (invoiceAt < 0 || itineraryAt < invoiceAt) ? 'itinerary' : 'invoice';
    }
    const numberPatterns = [/(?:发票号码|发票号|票据号码)[：:]?([A-Z0-9]{8,24})/i, /\b(\d{20})\b/];
    for (const pattern of numberPatterns) { const match = compact.match(pattern); if (match) { result.number = match[1]; break; } }
    if (!result.number && /行程单/.test(attachment.name)) {
      const match = compact.match(/(?:申请单号|行程单号|订单号)[：:]?([A-Z0-9]{6,24})/i); if (match) result.number = match[1];
    }
    if (result.role === 'invoice') {
      const amountPatterns = [/(?:价税合计|小写)[（(]?小写?[）)]?[：:]?[¥￥]?([0-9,]+(?:\.[0-9]{1,2})?)/i, /(?:票价|合计金额|发票金额|金额)[：:]?[¥￥]?([0-9,]+(?:\.[0-9]{1,2})?)/i];
      for (const pattern of amountPatterns) { const match = compact.match(pattern); if (match) { result.amount = C.parseCents(match[1]) ?? 0; if (result.amount) break; } }
    }
    const dateMatch = compact.match(/(?:乘车日期|出发日期|开票日期|日期)[：:]?(20\d{2})[-年](\d{1,2})[-月](\d{1,2})/);
    if (dateMatch) result.date = `${dateMatch[1]}-${C.pad(dateMatch[2])}-${C.pad(dateMatch[3])}`;
    const origin = compact.match(/(?:出发站|起点|出发地)[：:]?([^到至]{2,16}?)(?:到达站|终点|目的地|$)/);
    const destination = compact.match(/(?:到达站|终点|目的地)[：:]?([^票日车座席]{2,16})/);
    if (origin || destination) result.route = { origin: cityFromStation(origin?.[1] || ''), destination: cityFromStation(destination?.[1] || '') };
  } catch (error) { console.warn('PDF recognition failed', attachment.name, error); }
  attachment.number = result.number;
  attachment.amount = result.amount;
  attachment.pageCount = result.pageCount;
  return result;
}

function cityFromStation(value) {
  let city = String(value || '').replace(/[：:]/g, '').trim().replace(/(?:站|机场)$/g, '');
  const suffixes = ['虹桥', '浦东', '首都', '大兴', '白云', '宝安', '东', '西', '南', '北'];
  for (const suffix of suffixes) if (city.length > 2 && city.endsWith(suffix)) city = city.slice(0, -suffix.length);
  return city;
}

function applyRecognition(expense, file) {
  if (file.date) expense.dates = [file.date];
  if (file.route) {
    if (file.route.origin) { expense.origin = file.route.origin; expense.originIsCustom = false; }
    if (file.route.destination) { expense.destination = file.route.destination; expense.destinationIsCustom = false; }
    if (!expense.departureTime && file.date) expense.departureTime = file.date;
    if (!expense.arrivalTime && file.date) expense.arrivalTime = file.date;
  }
  if (file.amount) {
    expense.unitPrice = file.amount;
    if (['火车', '飞机', '打车', '住宿'].includes(expense.kind)) expense.totalAmount = file.amount;
  }
}

async function attachTripFiles(claim, files, kind) {
  const invoices = files.filter(file => file.role !== 'itinerary');
  const itineraries = files.filter(file => file.role === 'itinerary');
  for (const file of invoices) {
    const expense = C.makeExpense(kind, '0', claim.travelerNames?.[0] || null);
    expense.invoices.push(file.attachment); applyRecognition(expense, file);
    if (kind === '住宿') expense.totalAmount = file.amount || 0;
    claim.expenses.push(expense);
  }
  for (const file of itineraries) {
    let expense = claim.expenses.find(item => item.kind === '打车' && item.invoices.some(invoice => invoice.number && invoice.number === file.attachment.number));
    if (!expense) expense = claim.expenses.find(item => item.kind === '打车' && !(item.itineraries || []).length);
    if (!expense) { expense = C.makeExpense('打车', '0', claim.travelerNames?.[0] || null); claim.expenses.push(expense); }
    expense.itineraries = expense.itineraries || []; expense.itineraries.push(file.attachment);
  }
  C.syncLedger(claim);
}

async function deleteExpense(id) {
  const claim = getClaim(), expense = claim?.expenses.find(item => item.id === id); if (!expense) return;
  for (const file of [...(expense.invoices || []), ...(expense.itineraries || [])]) await API.deleteAttachment(file.storedName);
  claim.expenses = claim.expenses.filter(item => item.id !== id); C.syncLedger(claim); queueSave(); renderClaim();
}

async function copyExpense(id) {
  const claim = getClaim(), source = claim?.expenses.find(item => item.id === id); if (!source) return;
  const copy = C.clone(source); copy.id = C.uuid(); const used = new Set(claim.expenses.flatMap(item => [...(item.invoices || []), ...(item.itineraries || [])]).map(file => file.name.toLowerCase()));
  for (const property of ['invoices', 'itineraries']) {
    copy[property] = [];
    for (const file of source[property] || []) {
      try {
        const duplicate = await API.duplicateAttachment(file.storedName);
        copy[property].push({ ...file, id: duplicate.id, storedName: duplicate.storedName, name: C.uniqueFilename(file.name, used) });
      } catch (error) { showError(error); }
    }
  }
  claim.expenses.push(copy); C.syncLedger(claim); queueSave(); renderClaim();
}

function findInvoice(id) {
  for (const claim of state.claims) for (const expense of claim.expenses || []) {
    const invoice = (expense.invoices || []).find(item => item.id === id); if (invoice) return { claim, expense, invoice };
  }
  return null;
}
function findAttachmentByDOM(element) {
  const claim = getClaim(); if (!claim) return null;
  const expense = claim.expenses.find(item => item.id === element.dataset.expenseId); if (!expense) return null;
  const property = element.dataset.scope === 'itinerary' ? 'itineraries' : 'invoices';
  const index = (expense[property] || []).findIndex(file => file.id === element.dataset.fileId);
  return index >= 0 ? { claim, expense, property, index, file: expense[property][index] } : null;
}
async function removeFoundAttachment(found) {
  await API.deleteAttachment(found.file.storedName);
  found.expense[found.property].splice(found.index, 1);
  C.syncLedger(found.claim); queueSave(); renderClaim();
}
async function deleteAttachment(found) { await removeFoundAttachment(found); showToast('附件已删除'); }

async function deleteLedgerRow(id) {
  const claim = getClaim(), entry = claim?.invoiceLedgerEntries?.find(item => item.id === id); if (!entry) return;
  const expense = claim.expenses.find(item => item.id === entry.expenseID); const invoice = expense?.invoices.find(item => item.id === entry.invoiceID);
  if (invoice) { await API.deleteAttachment(invoice.storedName); expense.invoices = expense.invoices.filter(item => item.id !== invoice.id); }
  claim.invoiceLedgerEntries = claim.invoiceLedgerEntries.filter(item => item.id !== id);
  queueSave(); renderClaim();
}

async function copyLedgerRow(id) {
  const claim = getClaim(), entry = claim?.invoiceLedgerEntries?.find(item => item.id === id); if (!entry) return;
  const expense = claim.expenses.find(item => item.id === entry.expenseID), invoice = expense?.invoices.find(item => item.id === entry.invoiceID);
  if (!invoice) return;
  try {
    const duplicate = await API.duplicateAttachment(invoice.storedName); const used = new Set(claim.expenses.flatMap(item => item.invoices || []).map(item => item.name.toLowerCase()));
    expense.invoices.push({ ...invoice, id: duplicate.id, storedName: duplicate.storedName, name: C.uniqueFilename(invoice.name, used) });
    C.syncLedger(claim); queueSave(); renderClaim(); showToast('发票行已复制');
  } catch (error) { showError(error); }
}

async function replaceLedgerRow(id) {
  const claim = getClaim(), entry = claim?.invoiceLedgerEntries?.find(item => item.id === id); if (!entry) return;
  const expense = claim.expenses.find(item => item.id === entry.expenseID); if (!expense) return;
  try {
    const raw = await API.importAttachments({ title: '替换发票' }); if (!raw.length) return;
    const files = await prepareImportedFiles(raw.slice(0, 1), expense.kind); const next = files[0];
    const index = expense.invoices.findIndex(item => item.id === entry.invoiceID);
    const previous = index >= 0 ? expense.invoices[index] : null;
    if (previous) await API.deleteAttachment(previous.storedName);
    if (index >= 0) expense.invoices[index] = next.attachment; else expense.invoices.push(next.attachment);
    applyRecognition(expense, next); C.syncLedger(claim); queueSave(); renderClaim();
  } catch (error) { showError(error); }
}

async function importCover() {
  const claim = getClaim(); if (!claim) return;
  try {
    const raw = await API.importAttachments({ title: '上传报销单' }); if (!raw.length) return;
    const used = new Set((claim.covers || []).map(file => file.name.toLowerCase()));
    for (const file of raw) { file.name = C.uniqueFilename(file.name, used); claim.covers.push(file); }
    queueSave(); renderClaim();
  } catch (error) { showError(error); }
}

function renameAttachment(found) {
  openTextModal('重命名附件', '输入新的文件名', found.file.name, async value => {
    const used = new Set(found.claim.expenses.flatMap(expense => [...(expense.invoices || []), ...(expense.itineraries || [])]).filter(file => file.id !== found.file.id).map(file => file.name.toLowerCase()));
    found.file.name = C.uniqueFilename(value, used); queueSave(); closeModal(); renderClaim();
  });
}
async function copyAttachment(found) {
  try {
    await API.copyAttachmentFile(found.file.storedName);
    showToast('附件已复制，可直接粘贴');
  } catch (error) { showError(error); }
}

async function renameRecord(id) {
  const claim = state.claims.find(item => item.id === id); if (!claim) return;
  openTextModal('重命名报销记录', '名称允许重复', claim.title, async value => {
    if (!value.trim()) return;
    claim.title = value.trim(); await API.saveClaim(claim); closeModal(); renderAll();
  });
}
async function deleteIds(ids) {
  if (!ids.length) return;
  if (!confirm(`确定删除选中的 ${ids.length} 条报销记录吗？附件文件也会一并删除。`)) return;
  for (const id of ids) {
    const claim = state.claims.find(item => item.id === id);
    for (const file of claim?.expenses?.flatMap(expense => [...(expense.invoices || []), ...(expense.itineraries || [])]) || []) await API.deleteAttachment(file.storedName);
  }
  await API.deleteClaims(ids); state.claims = state.claims.filter(item => !ids.includes(item.id));
  if (ids.includes(state.selectedId)) { state.selectedId = state.claims[0]?.id || null; state.kindFilter = state.claims[0]?.kind || null; }
  state.checked.clear(); state.batch = false; renderAll();
}
async function deleteChecked() { return deleteIds([...state.checked]); }

function claimAttachmentEntries(claim) {
  const entries = [];
  for (const cover of claim.covers || []) entries.push({ file: cover, scope: 'cover', role: 'cover', kind: '报销单' });
  for (const expense of claim.expenses || []) {
    for (const file of expense.invoices || []) entries.push({ file, scope: 'invoice', role: 'invoice', kind: expense.kind, expense });
    for (const file of expense.itineraries || []) entries.push({ file, scope: 'itinerary', role: 'itinerary', kind: expense.kind, expense });
  }
  return entries;
}

async function previewFile(scope, expenseId, fileId) {
  const claim = getClaim(); if (!claim) return;
  const entries = claimAttachmentEntries(claim);
  let index = entries.findIndex(entry => entry.file.id === fileId && (scope === 'cover' || entry.expense?.id === expenseId));
  if (index < 0) index = entries.findIndex(entry => entry.file.id === fileId);
  if (index < 0) return showToast('未找到附件', true);
  openAttachmentPreview(claim, entries, index);
}

async function openAttachmentPreview(claim, entries, index) {
  previewState = { claim, entries, index, scale: 1, x: 0, y: 0, dragging: false, dataUrl: '', objectUrl: '' };
  openModal(`
    <div class="modal-card preview" style="position:relative">
      <div class="modal-header"><div><h2 id="preview-title">正在载入附件…</h2><p id="preview-subtitle"></p></div>
        <button class="btn icon-only" data-action="copy-preview" title="复制">⧉</button>
        <button class="btn icon-only" data-action="download-preview" title="下载">⇩</button>
        <button class="btn icon-only" data-action="close-modal" title="关闭">×</button>
      </div>
      <div class="preview-canvas-wrap" id="preview-canvas-wrap"><div class="spinner"></div></div>
      <button class="preview-nav previous" data-action="preview-previous" id="preview-previous">‹</button>
      <button class="preview-nav next" data-action="preview-next" id="preview-next">›</button>
    </div>`, true);
  bindPreviewGestures();
  await renderPreviewCurrent();
}

async function renderPreviewCurrent() {
  if (!previewState) return;
  const { entries, claim } = previewState; const entry = entries[previewState.index];
  const title = document.getElementById('preview-title'), subtitle = document.getElementById('preview-subtitle'), wrap = document.getElementById('preview-canvas-wrap');
  if (!title || !wrap) return;
  title.textContent = entry.file.name;
  subtitle.textContent = `${entry.kind} · ${previewState.index + 1} / ${entries.length} · 滚轮缩放，拖动查看，双击适应窗口`;
  document.getElementById('preview-previous').style.display = entries.length > 1 ? '' : 'none';
  document.getElementById('preview-next').style.display = entries.length > 1 ? '' : 'none';
  wrap.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await API.readAttachment(entry.file.storedName);
    const bytes = new Uint8Array(data.data);
    if (data.mime === 'application/pdf') previewState.dataUrl = await renderPdfPageData(bytes, 1);
    else previewState.dataUrl = await renderImageData(bytes, data.mime);
    previewState.scale = 1; previewState.x = 0; previewState.y = 0;
    wrap.innerHTML = `<img id="preview-image" class="preview-canvas" draggable="false" src="${previewState.dataUrl}" alt="${attr(entry.file.name)}">`;
    applyPreviewTransform();
  } catch (error) {
    wrap.innerHTML = `<div class="preview-empty">无法读取附件：${escapeHTML(error.message || error)}</div>`;
  }
}

function bindPreviewGestures() {
  const wrap = document.getElementById('preview-canvas-wrap'); if (!wrap) return;
  wrap.addEventListener('wheel', event => {
    event.preventDefault(); if (!previewState) return;
    previewState.scale = Math.max(.2, Math.min(6, previewState.scale * (event.deltaY < 0 ? 1.12 : .89)));
    applyPreviewTransform();
  }, { passive: false });
  wrap.addEventListener('dblclick', () => { if (!previewState) return; previewState.scale = 1; previewState.x = 0; previewState.y = 0; applyPreviewTransform(); });
  wrap.addEventListener('pointerdown', event => {
    if (!previewState || !event.target.matches('#preview-image')) return;
    previewState.dragging = true; previewState.startX = event.clientX - previewState.x; previewState.startY = event.clientY - previewState.y;
    event.target.setPointerCapture(event.pointerId);
  });
  wrap.addEventListener('pointermove', event => {
    if (!previewState?.dragging) return;
    previewState.x = event.clientX - previewState.startX; previewState.y = event.clientY - previewState.startY; applyPreviewTransform();
  });
  wrap.addEventListener('pointerup', event => { if (previewState) previewState.dragging = false; });
  wrap.addEventListener('pointercancel', () => { if (previewState) previewState.dragging = false; });
}
function applyPreviewTransform() {
  const image = document.getElementById('preview-image'); if (!image || !previewState) return;
  image.style.transform = `translate(${previewState.x}px, ${previewState.y}px) scale(${previewState.scale})`;
  image.style.transformOrigin = 'center center';
}
async function navigatePreview(direction) {
  if (!previewState) return;
  previewState.index = (previewState.index + direction + previewState.entries.length) % previewState.entries.length;
  await renderPreviewCurrent();
}

function downloadPreview() {
  if (!previewState?.dataUrl) return;
  const entry = previewState.entries[previewState.index];
  const link = document.createElement('a'); link.href = previewState.dataUrl; link.download = entry.file.name || '附件';
  document.body.appendChild(link); link.click(); link.remove();
}
async function downloadAttachment(file) {
  const data = await API.readAttachment(file.storedName); const blob = new Blob([data.data], { type: data.mime });
  const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = file.name; document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function renderPdfPageData(bytes, pageNumber = 1, itinerary = false) {
  if (!window.pdfjsLib) throw new Error('PDF 预览组件未加载');
  window.pdfjsLib.GlobalWorkerOptions.workerSrc = new URL('vendor/pdf.worker.min.js', location.href).href;
  const pdf = await window.pdfjsLib.getDocument({ data: bytes }).promise;
  const page = await pdf.getPage(Math.min(pageNumber, pdf.numPages)); const base = page.getViewport({ scale: 1 });
  const scale = Math.min(2, 1600 / base.width); const viewport = page.getViewport({ scale });
  const canvas = document.createElement('canvas'); canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
  await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
  if (itinerary) formatItineraryCanvas(canvas);
  return canvas.toDataURL('image/jpeg', .93);
}
async function renderImageData(bytes, mime, itinerary = false) {
  const blob = new Blob([bytes], { type: mime }); const url = URL.createObjectURL(blob);
  try {
    const image = await new Promise((resolve, reject) => { const element = new Image(); element.onload = () => resolve(element); element.onerror = reject; element.src = url; });
    const canvas = document.createElement('canvas'); const ratio = Math.min(1, 1600 / image.naturalWidth); canvas.width = image.naturalWidth * ratio; canvas.height = image.naturalHeight * ratio;
    const context = canvas.getContext('2d'); context.fillStyle = 'white'; context.fillRect(0, 0, canvas.width, canvas.height); context.drawImage(image, 0, 0, canvas.width, canvas.height);
    if (itinerary) formatItineraryCanvas(canvas);
    return canvas.toDataURL('image/jpeg', .93);
  } finally { URL.revokeObjectURL(url); }
}
function firstInkRow(canvas) {
  const context = canvas.getContext('2d', { willReadFrequently: true }); const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
  for (let y = 0; y < canvas.height; y++) {
    for (let x = 0; x < canvas.width; x += 2) {
      const offset = (y * canvas.width + x) * 4;
      if (data[offset] < 245 || data[offset + 1] < 245 || data[offset + 2] < 245) return y;
    }
  }
  return 0;
}
function formatItineraryCanvas(canvas) {
  const crop = C.itineraryPrintCrop(canvas.width, canvas.height, firstInkRow(canvas));
  const output = document.createElement('canvas'); output.width = crop.width; output.height = crop.height;
  const context = output.getContext('2d'); context.fillStyle = 'white'; context.fillRect(0, 0, output.width, output.height);
  context.imageSmoothingEnabled = true; context.imageSmoothingQuality = 'high';
  context.drawImage(canvas, crop.sx, crop.sy, crop.sw, crop.sh, 0, 0, output.width, output.height);
  canvas.width = output.width; canvas.height = output.height; canvas.getContext('2d').drawImage(output, 0, 0);
}

function openSummaryModal() {
  const claim = getClaim(); if (!claim) return;
  modalSummaryTab = '总览';
  renderSummaryModal(claim);
}
function renderSummaryModal(claim) {
  const names = ['总览', ...C.personNames(claim).filter(Boolean)];
  const person = modalSummaryTab === '总览' ? null : modalSummaryTab;
  const text = C.summaryText(claim, person);
  openModal(`<div class="modal-card">
    <div class="modal-header"><div><h2>报销清单预览</h2><p>${escapeHTML(claim.title)} · ${escapeHTML(claim.savedStatus)}</p></div><button class="btn icon-only" data-action="copy-summary" data-text="${attr(text)}" title="复制清单">⧉</button><button class="btn icon-only" data-action="close-modal" title="关闭">×</button></div>
    <div class="modal-body"><div class="modal-tabs">${names.map(name => `<button class="modal-tab ${modalSummaryTab === name ? 'active' : ''}" data-modal-tab="${attr(name)}">${escapeHTML(name)}</button>`).join('')}</div><div class="summary-paper">${escapeHTML(text)}</div></div>
  </div>`);
  document.querySelectorAll('[data-modal-tab]').forEach(tab => tab.addEventListener('click', () => { modalSummaryTab = tab.dataset.modalTab; renderSummaryModal(claim); }));
}

function openFormPreview() {
  const claim = getClaim(); if (!claim) return;
  const names = C.personNames(claim).filter(Boolean);
  modalSummaryTab = names[0] || '总览';
  renderFormModal(claim);
}
function renderFormModal(claim) {
  const person = modalSummaryTab === '总览' ? (claim.travelerNames?.[0] || null) : modalSummaryTab;
  const expenses = person ? C.personExpenses(claim, person) : claim.expenses;
  const total = claim.kind === '补助' ? C.claimTotal(claim) : expenses.reduce((sum, expense) => sum + C.expenseTotal(expense, claim), 0);
  const names = C.personNames(claim).filter(Boolean);
  const groups = {};
  for (const expense of expenses) groups[expense.kind] = (groups[expense.kind] || 0) + C.expenseTotal(expense, claim);
  openModal(`<div class="modal-card">
    <div class="modal-header"><div><h2>报销单预览</h2><p>可选中文字复制，金额按当前记录计算</p></div><button class="btn icon-only" data-action="copy-form" title="复制">⧉</button><button class="btn icon-only" data-action="close-modal">×</button></div>
    <div class="modal-body"><div class="modal-tabs">${names.map(name => `<button class="modal-tab ${person === name ? 'active' : ''}" data-form-person="${attr(name)}">${escapeHTML(name)}</button>`).join('')}</div>
      <div class="summary-paper" style="white-space:normal;background:white;padding:28px;line-height:1.9">
        <h2 style="text-align:center;font-size:22px;letter-spacing:8px;margin-bottom:22px">差旅费报销单</h2>
        <div style="display:grid;grid-template-columns:100px 1fr 100px 1fr;border:1px solid #aaa;border-bottom:0"><div style="padding:8px;background:#f7f8fa">部门</div><div style="padding:8px">${escapeHTML(claim.department || '')}</div><div style="padding:8px;background:#f7f8fa">报销人</div><div style="padding:8px">${escapeHTML(person || '')}</div></div>
        <div style="display:grid;grid-template-columns:100px 1fr;border:1px solid #aaa;border-bottom:0"><div style="padding:8px;background:#f7f8fa">出差事由</div><div style="padding:8px">${escapeHTML(claim.tripPurpose || '')}</div></div>
        <div style="display:grid;grid-template-columns:100px 1fr;border:1px solid #aaa"><div style="padding:8px;background:#f7f8fa">日期</div><div style="padding:8px">${escapeHTML(C.personDates(claim, person).join('、') || '')}</div></div>
        <table class="data-table" style="min-width:0;margin-top:14px"><thead><tr><th>类别</th><th>金额</th></tr></thead><tbody>${Object.entries(groups).map(([kind, amount]) => `<tr><td>${escapeHTML(kind)}</td><td>${C.formatMoney(amount)}</td></tr>`).join('')}</tbody></table>
        <div style="display:flex;justify-content:flex-end;gap:16px;margin-top:16px"><strong>合计：${C.formatMoney(total)}</strong><strong>${C.chineseMoney(total)}</strong></div>
        <p style="margin-top:20px;color:#738096">备注：${escapeHTML(claim.note || '无')}</p>
      </div>
    </div>
  </div>`);
  document.querySelectorAll('[data-form-person]').forEach(tab => tab.addEventListener('click', () => { modalSummaryTab = tab.dataset.formPerson; renderFormModal(claim); }));
  document.querySelector('[data-action="copy-form"]')?.addEventListener('click', () => {
    API.copyText(`差旅费报销单\n部门：${claim.department || ''}\n报销人：${person || ''}\n出差事由：${claim.tripPurpose || ''}\n日期：${C.personDates(claim, person).join('、')}\n适用金额：${C.formatMoney(total)}\n${C.chineseMoney(total)}`);
    showToast('报销单内容已复制');
  });
}

function openTextModal(title, subtitle, value, save) {
  openModal(`<div class="modal-card small"><div class="modal-header"><div><h2>${escapeHTML(title)}</h2><p>${escapeHTML(subtitle)}</p></div><button class="btn icon-only" data-action="close-modal">×</button></div><div class="modal-body"><div class="field"><label>名称</label><input id="text-modal-input" value="${attr(value)}" autofocus></div><div class="header-actions" style="justify-content:flex-end;margin-top:14px"><button class="btn" data-action="close-modal">取消</button><button class="btn primary" id="text-modal-save">保存</button></div></div></div>`);
  const input = document.getElementById('text-modal-input'); setTimeout(() => { input.focus(); input.select(); }, 30);
  const commit = () => save(input.value);
  document.getElementById('text-modal-save').addEventListener('click', commit); input.addEventListener('keydown', event => { if (event.key === 'Enter') commit(); });
}

async function exportLedger() {
  const claim = getClaim(); if (!claim) return;
  const rows = sortedLedgerRows(claim).map(row => ({
    date: row.date, claimant: row.claimant, number: row.invoice?.number || '', invoiceAmount: row.invoice?.amount || 0,
    reimbursementAmount: row.reimbursementAmount || 0, detail: row.detail, purpose: row.purpose
  }));
  try {
    const destination = await API.exportLedger({ defaultName: claim.title, rows });
    if (destination) showToast('报销清单已导出');
  } catch (error) { showError(error); }
}

async function exportInvoices(claim) {
  if (!claim) return;
  const files = claimAttachmentEntries(claim).map(entry => ({ name: entry.file.name, storedName: entry.file.storedName }));
  if (!files.length) return showToast('当前记录没有可导出的附件', true);
  try {
    const destination = await API.exportAttachmentZip({ defaultName: `${claim.title}-发票文件`, files });
    if (destination) showToast('发票文件已导出');
  } catch (error) { showError(error); }
}

async function exportInvoicesAll() {
  const files = state.claims.flatMap(claim => claimAttachmentEntries(claim).map(entry => ({ name: `${C.sanitizeFilename(claim.title)}-${entry.file.name}`, storedName: entry.file.storedName })));
  if (!files.length) return showToast('没有可导出的附件', true);
  try { const destination = await API.exportAttachmentZip({ defaultName: '全部报销发票', files }); if (destination) showToast('全部发票已导出'); }
  catch (error) { showError(error); }
}

async function exportPrint(claim) {
  if (!claim) return;
  try {
    showToast('正在生成打印文档，请稍候…');
    const pages = await preparePrintPages(claim);
    if (!pages.length) return showToast('当前记录没有可打印的附件', true);
    const destination = await API.exportPrintDocx({ defaultName: claim.title, pages });
    if (destination) showToast('打印文档已导出');
  } catch (error) { showError(error); }
}

async function exportPrintAll() {
  try {
    const pages = [];
    for (const claim of state.claims) pages.push(...await preparePrintPages(claim));
    if (!pages.length) return showToast('没有可打印的附件', true);
    const destination = await API.exportPrintDocx({ defaultName: '报销发票汇总', pages });
    if (destination) showToast('打印文档已导出');
  } catch (error) { showError(error); }
}

async function preparePrintPages(claim) {
  const entries = claimAttachmentEntries(claim);
  const pages = [];
  for (const entry of entries) {
    const data = await API.readAttachment(entry.file.storedName); const bytes = new Uint8Array(data.data);
    let images = [];
    if (data.mime === 'application/pdf') {
      if (!window.pdfjsLib) throw new Error('PDF 打印组件未加载');
      window.pdfjsLib.GlobalWorkerOptions.workerSrc = new URL('vendor/pdf.worker.min.js', location.href).href;
      const pdf = await window.pdfjsLib.getDocument({ data: bytes }).promise;
      for (let page = 1; page <= pdf.numPages; page++) images.push(await renderPdfPageData(bytes, page, entry.role === 'itinerary'));
    } else {
      images.push(await renderImageData(bytes, data.mime, entry.role === 'itinerary'));
    }
    if (entry.kind === '火车' && entry.role === 'invoice') images = [...images, ...images];
    for (const dataUrl of images) pages.push({ dataUrl, ...(await fitPrintImage(dataUrl)) });
  }
  return pages;
}
async function imageDimensions(dataUrl) {
  return new Promise((resolve, reject) => { const image = new Image(); image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight }); image.onerror = reject; image.src = dataUrl; });
}
async function fitPrintImage(dataUrl) {
  const size = await imageDimensions(dataUrl); const ratio = size.width / size.height;
  let width = 690, height = width / ratio;
  if (height > 350) { height = 350; width = height * ratio; }
  return { width: Math.round(width), height: Math.round(height) };
}

function toggleLedgerSort(column) {
  if (column === 'sequence') return;
  if (state.ledgerSort.column !== column) state.ledgerSort = { column, ascending: true };
  else if (state.ledgerSort.ascending === true) state.ledgerSort = { column, ascending: false };
  else state.ledgerSort = { column: '', ascending: null };
  renderClaim();
}

function openModal(content, preview = false) {
  const root = document.getElementById('modal-root'), backdrop = document.getElementById('modal-backdrop');
  root.innerHTML = content; root.classList.remove('hidden'); backdrop.classList.remove('hidden');
  if (preview) root.querySelector('.modal-card')?.classList.add('preview');
}
function closeModal() {
  const root = document.getElementById('modal-root');
  if (previewState?.objectUrl) URL.revokeObjectURL(previewState.objectUrl);
  previewState = null;
  root.classList.add('hidden'); root.innerHTML = ''; document.getElementById('modal-backdrop').classList.add('hidden');
}

init();
