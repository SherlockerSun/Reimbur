(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReimburCore = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  const KINDS = ['出差', '餐补', '补助'];
  const TRIP_TYPES = ['出差补助', '火车', '飞机', '打车', '住宿'];
  const STATUSES = ['未报销', '待审批', '已归档'];
  const TYPE_LABEL = { '补助': '补贴', '补助报销': '补贴报销' };

  function uuid() {
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') return globalThis.crypto.randomUUID().toUpperCase();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    }).toUpperCase();
  }

  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function pad(value) { return String(value).padStart(2, '0'); }
  function dayKey(date = new Date()) {
    const d = date instanceof Date ? date : new Date(date);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }
  function compactDate(date = new Date()) { return dayKey(date).replaceAll('-', ''); }
  function displayKind(kind) { return kind === '补助' ? '补贴' : kind; }

  function parseCents(value) {
    const normalized = String(value ?? '').trim().replaceAll(',', '');
    if (!/^\d{1,9}(\.\d{0,2})?$/.test(normalized)) return null;
    return Math.round(Number(normalized) * 100);
  }
  function centsFromNumber(value) {
    const number = Number(value || 0);
    return Number.isFinite(number) ? Math.round(number * 100) : 0;
  }
  function inputMoney(cents) { return (Number(cents || 0) / 100).toFixed(2); }
  function formatMoney(cents) {
    return `¥${(Number(cents || 0) / 100).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }
  function chineseMoney(cents) {
    const digits = '零壹贰叁肆伍陆柒捌玖';
    const units = ['', '拾', '佰', '仟'];
    const groups = ['', '万', '亿'];
    let amount = Math.max(0, Math.round(Number(cents || 0)));
    const yuan = Math.floor(amount / 100);
    const jiao = Math.floor(amount % 100 / 10);
    const fen = amount % 10;
    function integerText(number) {
      if (number === 0) return '零';
      let result = '', groupIndex = 0, zero = false;
      while (number > 0) {
        const group = number % 10000;
        let groupText = '', digitIndex = 0, local = group;
        while (local > 0) {
          const digit = local % 10;
          if (digit === 0) { if (groupText) zero = true; }
          else { groupText = digits[digit] + units[digitIndex] + (zero ? '零' : '') + groupText; zero = false; }
          local = Math.floor(local / 10); digitIndex++;
        }
        if (groupText) result = groupText + groups[groupIndex] + (zero && result ? '零' : '') + result;
        else if (result && !result.startsWith('零')) result = '零' + result;
        number = Math.floor(number / 10000); groupIndex++;
      }
      return result.replace(/零+/g, '零').replace(/零$/g, '');
    }
    let result = integerText(yuan) + '元';
    if (!jiao && !fen) return result + '整';
    result += jiao ? digits[jiao] + '角' : '零';
    if (fen) result += digits[fen] + '分';
    return result;
  }

  function defaultSettings() {
    return {
      traveler: '', department: '', tripPurpose: '', subsidyPrice: '50.00', mealPrice: '30.00',
      caption: '轻记每一笔，安心每一天', invoiceFormat: '{报销人}{发票号码}', itineraryFormat: '{报销人}{行程单号}',
      startup: 'home'
    };
  }

  function createClaim(kind, settings = defaultSettings(), now = new Date()) {
    const id = uuid();
    const names = String(settings.traveler || '').split(/[，,、\s]+/).map(v => v.trim()).filter(Boolean);
    const claim = {
      id, title: `${displayKind(kind)}报销${compactDate(now)}`, kind, savedStatus: '未报销',
      reimbursementPurpose: '', department: settings.department || '', tripPurpose: kind === '出差' ? settings.tripPurpose || '' : '',
      allowanceAmount: kind === '补助' ? 0 : null, travelers: names.length, travelerNames: names,
      dates: [], note: '', expenses: [], expenseOrder: [], defaultExpenseRowOrder: [], defaultLedgerRowOrder: [],
      covers: [], createdAt: now.toISOString(), updatedAt: now.toISOString(), invoiceLedgerEntries: kind === '出差' ? null : []
    };
    if (kind === '餐补') claim.expenses.push(makeExpense('餐补', settings.mealPrice));
    if (kind === '补助') claim.expenses.push(makeExpense('补助', '0'));
    return claim;
  }

  function makeExpense(kind, price = '0', claimant = null) {
    return {
      id: uuid(), kind, unitPrice: typeof price === 'number' ? price : (parseCents(price) ?? 0), quantity: 1,
      origin: '', destination: '', originIsCustom: false, destinationIsCustom: false,
      departureTime: '', arrivalTime: '', note: '', dates: null, invoices: [], itineraries: [],
      claimant, subsidyGroupID: kind === '出差补助' ? uuid() : null, totalAmount: null, invoiceTotalLinked: false
    };
  }

  function uniqueNames(names) {
    const seen = new Set();
    return (names || []).map(v => String(v).trim()).filter(v => v && !seen.has(v) && seen.add(v));
  }

  function normalize(claim) {
    claim.travelerNames = uniqueNames(claim.travelerNames || []);
    claim.travelers = claim.travelerNames.length;
    claim.dates = [...new Set(claim.dates || [])].sort();
    claim.covers = claim.covers || [];
    claim.expenses = claim.expenses || [];
    claim.expenseOrder = claim.expenseOrder || [];
    claim.invoiceLedgerEntries = claim.invoiceLedgerEntries === undefined ? null : claim.invoiceLedgerEntries;
    claim.savedStatus = STATUSES.includes(claim.savedStatus) ? claim.savedStatus : '未报销';
    if (claim.allowanceAmount !== null && claim.allowanceAmount !== undefined) claim.allowanceAmount = Number(claim.allowanceAmount);
    for (const expense of claim.expenses) {
      expense.invoices = expense.invoices || [];
      expense.itineraries = expense.itineraries || [];
      expense.unitPrice = Number(expense.unitPrice || 0);
      if (expense.totalAmount !== null && expense.totalAmount !== undefined) expense.totalAmount = Number(expense.totalAmount);
      expense.claimant = expense.claimant || null;
    }
    syncLedger(claim);
    return claim;
  }

  function syncLedger(claim) {
    const invoices = new Map();
    for (const expense of claim.expenses || []) for (const invoice of expense.invoices || []) invoices.set(invoice.id, { invoice, expense });
    const existing = claim.invoiceLedgerEntries || [];
    const byInvoice = new Map(existing.filter(entry => entry.invoiceID).map(entry => [entry.invoiceID, entry]));
    const result = [];
    for (const [invoiceID, pair] of invoices) {
      const { invoice, expense } = pair;
      let entry = byInvoice.get(invoiceID);
      if (!entry) {
        entry = {
          id: invoice.id, expenseID: expense.id, invoiceID, date: (expense.dates || claim.dates || [])[0] || compactDate(new Date(claim.createdAt || Date.now())).replace(/(\d{4})(\d{2})(\d{2})/, '$1-$2-$3'),
          claimant: expense.claimant || claim.travelerNames?.[0] || null,
          reimbursementAmount: Number(invoice.amount || 0), detail: claim.kind === '出差' ? expense.kind : ''
        };
      }
      entry.expenseID = expense.id;
      entry.claimant = entry.claimant || expense.claimant || claim.travelerNames?.[0] || null;
      entry.detail = entry.detail || (claim.kind === '出差' ? expense.kind : expense.note || '');
      entry.reimbursementAmount = Number(entry.reimbursementAmount || 0);
      result.push(entry);
    }
    claim.invoiceLedgerEntries = result;
    return claim;
  }

  function expenseDays(expense, claim) {
    const dates = expense.dates || claim.dates || [];
    if (expense.kind === '住宿' && expense.dates == null) return Math.max(0, (claim.dates || []).length - 1);
    return dates.length;
  }
  function expenseTotal(expense, claim) {
    const invoiceTotal = (expense.invoices || []).reduce((sum, invoice) => sum + Number(invoice.amount || 0), 0);
    if (['火车', '飞机', '打车'].includes(expense.kind)) return expense.invoices?.length ? invoiceTotal : Number(expense.unitPrice || 0);
    if (expense.kind === '住宿') return expense.totalAmount != null ? Number(expense.totalAmount) : (expense.invoices?.length ? invoiceTotal : Number(expense.unitPrice || 0));
    if (expense.kind === '出差补助' || expense.kind === '餐补') return Number(expense.unitPrice || 0) * expenseDays(expense, claim);
    if (expense.kind === '补助') return claim.allowanceAmount != null ? Number(claim.allowanceAmount) : Number(expense.unitPrice || 0);
    return Number(expense.unitPrice || 0) * Math.max(1, expense.quantity || 1) * expenseDays(expense, claim);
  }
  function claimTotal(claim) {
    if (claim.kind === '补助' && claim.allowanceAmount != null) return Number(claim.allowanceAmount || 0);
    return (claim.expenses || []).reduce((sum, expense) => sum + expenseTotal(expense, claim), 0);
  }
  function invoiceTotal(claim) { return (claim.expenses || []).flatMap(e => e.invoices || []).reduce((sum, invoice) => sum + Number(invoice.amount || 0), 0); }
  function invoiceCount(claim) { return (claim.expenses || []).reduce((sum, e) => sum + (e.invoices || []).length, 0); }
  function difference(claim) { return claimTotal(claim) - invoiceTotal(claim); }

  function personNames(claim) {
    const names = uniqueNames([...(claim.travelerNames || []), ...(claim.expenses || []).map(e => e.claimant).filter(Boolean)]);
    return names.length ? names : [null];
  }
  function personExpenses(claim, name) {
    if (!name) return (claim.expenses || []).filter(e => !e.claimant);
    return (claim.expenses || []).filter(e => e.claimant === name);
  }
  function personDates(claim, name) {
    const expenses = personExpenses(claim, name);
    const allowance = expenses.filter(e => ['出差补助', '餐补', '补助'].includes(e.kind));
    if (allowance.length) return [...new Set(allowance.flatMap(e => e.dates || claim.dates || []))].sort();
    const ownDated = expenses.filter(e => e.dates != null);
    if (!ownDated.length) return [...(claim.dates || [])].sort();
    return [...new Set(ownDated.flatMap(e => e.dates || []))].sort();
  }
  function personDays(claim, name) { return personDates(claim, name).length; }
  function reimbursementDayCount(claim) {
    if (claim.kind === '补助') return 0;
    return Math.max(0, ...personNames(claim).map(name => personDays(claim, name)), (claim.dates || []).length);
  }
  function reimbursementDates(claim) {
    if (claim.kind === '补助') return [];
    return [...new Set(personNames(claim).flatMap(name => personDates(claim, name)))].sort();
  }
  function recordDetail(claim) {
    return `${claim.kind === '补助' ? '' : `${reimbursementDayCount(claim)}天 · `}${Math.max(1, claim.travelerNames?.length || 0)}人 · ${(claim.expenses || []).length}笔 · ${invoiceCount(claim)}份发票`;
  }
  function ledgerPurpose(claim) {
    if (claim.kind === '餐补') return '餐补报销';
    if (claim.kind === '出差') return claim.tripPurpose || '';
    return claim.reimbursementPurpose || '';
  }

  function expenseTypeOrder(claim) {
    const seen = new Set();
    return [...(claim.expenseOrder || []), ...TRIP_TYPES].filter(kind => !seen.has(kind) && seen.add(kind));
  }
  function rowInvoice(claim, entry) {
    const expense = (claim.expenses || []).find(e => e.id === entry.expenseID);
    return { expense, invoice: expense?.invoices?.find(i => i.id === entry.invoiceID) };
  }
  function ledgerRows(claim, typeOrder = true) {
    syncLedger(claim);
    const entries = [...(claim.invoiceLedgerEntries || [])];
    if (claim.kind !== '出差' || !typeOrder) return entries.map(entry => ({ ...entry, purpose: ledgerPurpose(claim), ...rowInvoice(claim, entry) }));
    const ranks = new Map(expenseTypeOrder(claim).map((kind, index) => [kind, index]));
    return entries.map((entry, index) => ({ entry, index })).sort((a, b) => {
      const ea = (claim.expenses || []).find(e => e.id === a.entry.expenseID);
      const eb = (claim.expenses || []).find(e => e.id === b.entry.expenseID);
      const ar = ranks.get(ea?.kind) ?? 999, br = ranks.get(eb?.kind) ?? 999;
      return ar === br ? a.index - b.index : ar - br;
    }).map(({ entry }) => ({ ...entry, purpose: ledgerPurpose(claim), ...rowInvoice(claim, entry) }));
  }

  function filterClaims(claims, filter = {}) {
    const search = String(filter.search || '').trim().toLowerCase();
    return (claims || []).filter(claim => {
      if (filter.kind && claim.kind !== filter.kind) return false;
      if (filter.status && claim.savedStatus !== filter.status) return false;
      if (filter.period) {
        const dates = claim.kind === '补助' ? [dayKey(claim.createdAt)] : reimbursementDates(claim);
        if (dates.length && !dates.some(date => date.startsWith(filter.period))) return false;
        if (!dates.length && !dayKey(claim.createdAt).startsWith(filter.period)) return false;
      }
      if (!search) return true;
      const haystack = [claim.title, claim.department, claim.tripPurpose, claim.reimbursementPurpose, claim.note, ...(claim.travelerNames || [])].join(' ').toLowerCase();
      return haystack.includes(search);
    }).sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  }

  function summaryText(claim, person = null) {
    const title = person ? `${claim.title} · ${person}` : claim.title;
    const lines = [title, `类型：${displayKind(claim.kind)}报销`, `状态：${claim.savedStatus}`];
    if (claim.kind === '出差') {
      lines.push(`部门：${claim.department || '未填写'}`, `出差人：${person || (claim.travelerNames || []).join('、') || '未填写'}`, `事由：${claim.tripPurpose || '未填写'}`);
    } else {
      lines.push(`报销人：${(claim.travelerNames || []).join('、') || '未填写'}`, `用途：${ledgerPurpose(claim) || '未填写'}`);
    }
    if (claim.kind !== '补助') lines.push(`日期：${(reimbursementDates(claim).join('、') || '未选择')}（${person ? personDays(claim, person) : reimbursementDayCount(claim)} 天）`);
    lines.push('', '费用明细');
    const expenses = person ? personExpenses(claim, person) : claim.expenses;
    for (const expense of expenses || []) {
      const route = ['火车', '飞机'].includes(expense.kind) ? ` ${expense.departureTime || ''} ${expense.origin || '未填起点'} → ${expense.arrivalTime || ''} ${expense.destination || '未填终点'}` : '';
      const day = ['出差补助', '餐补'].includes(expense.kind) ? ` ${expenseDays(expense, claim)}天 × ${formatMoney(expense.unitPrice)}` : '';
      lines.push(`· ${expense.kind}${route}${day}：${formatMoney(expenseTotal(expense, claim))}${expense.note ? `（${expense.note}）` : ''}`);
    }
    lines.push('', '报销清单');
    const rows = ledgerRows(claim).filter(row => !person || row.claimant === person);
    if (!rows.length) lines.push('暂无发票');
    rows.forEach((row, index) => {
      lines.push(`${index + 1}. ${row.date} · ${row.claimant || '未填写'} · ${row.detail || '未填写'}`);
      lines.push(`   发票号码：${row.invoice?.number || '未识别'}；票面 ${formatMoney(row.invoice?.amount || 0)}；报销单 ${formatMoney(row.reimbursementAmount || 0)}`);
    });
    lines.push('', `报销总额：${formatMoney(claimTotal(claim))}`, `发票总额：${formatMoney(invoiceTotal(claim))}`, `发票数量：${invoiceCount(claim)} 份`, `差额：${formatMoney(difference(claim))}`);
    if (claim.note) lines.push('', `备注：${claim.note}`);
    return lines.join('\n');
  }

  function stats(claims, period = '') {
    const records = (claims || []).filter(claim => !period || (claim.kind === '补助' ? dayKey(claim.createdAt) : (reimbursementDates(claim)[0] || dayKey(claim.createdAt))).startsWith(period));
    return {
      records,
      days: records.filter(c => c.kind !== '补助').reduce((sum, c) => sum + reimbursementDayCount(c), 0),
      total: records.reduce((sum, c) => sum + claimTotal(c), 0),
      invoiceTotal: records.reduce((sum, c) => sum + invoiceTotal(c), 0),
      invoiceCount: records.reduce((sum, c) => sum + invoiceCount(c), 0)
    };
  }

  function sanitizeFilename(value) {
    return String(value || '附件').replace(/[<>:"/\\|?*\x00-\x1F]/g, '_').trim().replace(/[. ]+$/g, '') || '附件';
  }
  function uniqueFilename(name, used) {
    const safe = sanitizeFilename(name);
    const ext = safe.lastIndexOf('.') > 0 ? safe.slice(safe.lastIndexOf('.')) : '';
    const stem = ext ? safe.slice(0, -ext.length) : safe;
    let candidate = safe, index = 1;
    while (used.has(candidate.toLowerCase())) candidate = `${stem}_${index++}${ext}`;
    used.add(candidate.toLowerCase());
    return candidate;
  }

  function itineraryPrintCrop(width, height, contentTop = 0) {
    const canvasWidth = 2400, aspectRatio = 1414 / 1000;
    const canvasHeight = Math.round(canvasWidth / aspectRatio);
    let sx = 0, sy = 0, sw = Math.max(1, Math.round(width)), sh = Math.max(1, Math.round(width / aspectRatio));
    if (width / height > aspectRatio) {
      sw = Math.max(1, Math.round(height * aspectRatio)); sh = Math.max(1, Math.round(height)); sx = Math.round((width - sw) / 2);
    } else {
      sh = Math.min(Math.max(1, Math.round(height)), sh);
      const margin = Math.max(8, Math.round(height / 100));
      sy = Math.min(Math.max(0, Math.round(contentTop) - margin), Math.max(0, Math.round(height) - sh));
    }
    return { sx, sy, sw, sh, width: canvasWidth, height: canvasHeight };
  }
  function attachFilename(attachment, claim, expense, role, settings) {
    const pattern = role === 'itinerary' ? settings.itineraryFormat : settings.invoiceFormat;
    const sourceStem = String(attachment.sourceName || attachment.name || '附件').replace(/\.[^.]+$/, '');
    const date = (expense.dates || claim.dates || [])[0] || dayKey(claim.createdAt);
    const replacements = {
      '{报销人}': expense.claimant || claim.travelerNames?.[0] || '', '{发票号码}': attachment.number || '',
      '{行程单号}': attachment.number || '', '{报销名称}': claim.title || '', '{费用类型}': expense.kind || '',
      '{原文件名}': sourceStem, '{日期}': date
    };
    let base = String(pattern || '{报销人}{发票号码}').replace(/\{[^}]+\}/g, token => replacements[token] ?? token).trim();
    if (!base) base = sourceStem;
    const ext = String(attachment.name || '').match(/\.[^.]+$/)?.[0] || '';
    return base.toLowerCase().endsWith(ext.toLowerCase()) ? base : base + ext;
  }

  return {
    KINDS, TRIP_TYPES, STATUSES, TYPE_LABEL, uuid, clone, pad, dayKey, compactDate, displayKind,
    parseCents, centsFromNumber, inputMoney, formatMoney, chineseMoney, defaultSettings,
    createClaim, makeExpense, uniqueNames, normalize, syncLedger, expenseDays, expenseTotal,
    claimTotal, invoiceTotal, invoiceCount, difference, personNames, personExpenses, personDates,
    personDays, reimbursementDayCount, reimbursementDates, recordDetail, ledgerPurpose,
    ledgerRows, filterClaims, summaryText, stats, sanitizeFilename, uniqueFilename, itineraryPrintCrop, attachFilename
  };
});
