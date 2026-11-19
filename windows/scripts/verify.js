'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const initSqlJs = require('sql.js');
const XLSX = require('xlsx');
const C = require('../src/core.js');

const settings = { ...C.defaultSettings(), traveler: '张三,李四', subsidyPrice: '50.00', mealPrice: '30.00' };
const trip = C.createClaim('出差', settings, new Date('2026-11-06T12:00:00+08:00'));
trip.dates = ['2026-11-01', '2026-11-02', '2026-11-03'];
trip.expenses = [
  C.makeExpense('住宿', '0', '李四'),
  C.makeExpense('火车', '0', '张三'),
  C.makeExpense('打车', '0', '李四'),
  C.makeExpense('出差补助', '50.00', '张三'),
  C.makeExpense('出差补助', '50.00', '李四')
];
trip.expenses[0].invoices.push({ id: C.uuid(), name: '住宿.pdf', storedName: 'x', amount: 60000, number: '10000000000000000001' });
trip.expenses[0].totalAmount = 60000;
trip.expenses[1].invoices.push({ id: C.uuid(), name: '火车.pdf', storedName: 'y', amount: 6900, number: '10000000000000000002' });
trip.expenses[2].invoices.push({ id: C.uuid(), name: '打车.pdf', storedName: 'z', amount: 3200, number: '10000000000000000003' });
trip.expenses[2].itineraries.push({ id: C.uuid(), name: '行程单.pdf', storedName: 'w', amount: 0, number: '10000000000000000003' });
trip.expenses[0].dates = ['2026-11-01', '2026-11-02'];
trip.expenses[1].departureTime = '2026-11-01 08:00'; trip.expenses[1].arrivalTime = '2026-11-01';
trip.expenses[2].dates = ['2026-11-03'];
trip.expenses[3].dates = ['2026-11-01', '2026-11-02', '2026-11-03'];
trip.expenses[4].dates = ['2026-11-02'];
C.normalize(trip);
assert.strictEqual(C.reimbursementDayCount(trip), 3);
assert.strictEqual(C.expenseDays(trip.expenses[0], trip), 2, 'one room night across a two-day stay');
assert.strictEqual(C.expenseTotal(trip.expenses[3], trip), 15000);
assert.strictEqual(C.invoiceTotal(trip), 70100);
assert.strictEqual(C.invoiceCount(trip), 3, 'itineraries never count as invoices');
assert.deepStrictEqual(C.ledgerRows(trip).map(row => row.detail), ['火车', '打车', '住宿'], 'trip ledger is grouped by type');

const meal = C.createClaim('餐补', settings, new Date('2026-11-06T12:00:00+08:00'));
meal.dates = ['2026-11-01', '2026-11-02'];
meal.expenses[0].unitPrice = 3000;
assert.strictEqual(C.claimTotal(meal), 6000);
meal.expenses[0].invoices.push({ id: C.uuid(), name: '餐补发票.pdf', storedName: 'meal', amount: 10000, number: '20000000000000000001' });
assert.strictEqual(C.claimTotal(meal), 6000, 'meal reimbursement stays independent from invoice amount');
assert.strictEqual(C.invoiceTotal(meal), 10000);

const allowance = C.createClaim('补助', settings, new Date('2026-11-06T12:00:00+08:00'));
allowance.allowanceAmount = 88800;
allowance.expenses[0].invoices.push({ id: C.uuid(), name: '补贴发票.pdf', storedName: 'allowance', amount: 50000, number: '30000000000000000001' });
assert.strictEqual(C.claimTotal(allowance), 88800);
assert.strictEqual(C.difference(allowance), 38800);
assert.strictEqual(C.chineseMoney(88800), '捌佰捌拾捌元整');

const filenames = new Set();
assert.strictEqual(C.uniqueFilename('张三发票.pdf', filenames), '张三发票.pdf');
assert.strictEqual(C.uniqueFilename('张三发票.pdf', filenames), '张三发票_1.pdf');
assert.strictEqual(C.uniqueFilename('张三发票.pdf', filenames), '张三发票_2.pdf');

const itineraryCrop = C.itineraryPrintCrop(1190, 1684, 60);
assert.deepStrictEqual(itineraryCrop, { sx: 0, sy: 43, sw: 1190, sh: 842, width: 2400, height: 1697 });
assert(Math.abs(itineraryCrop.width / itineraryCrop.height - 1414 / 1000) < 0.001, 'itinerary print uses the invoice aspect ratio');
assert(itineraryCrop.sy + itineraryCrop.sh < 1684, 'itinerary print keeps the top and discards the lower part');
const wideItineraryCrop = C.itineraryPrintCrop(2000, 500, 20);
assert.strictEqual(wideItineraryCrop.sh, 500);
assert(Math.abs(wideItineraryCrop.sw / wideItineraryCrop.sh - 1414 / 1000) < 0.001);

const exportRows = C.ledgerRows(trip).map(row => [row.date, row.claimant, row.invoice?.number, row.invoice?.amount / 100]);
const sheet = XLSX.utils.aoa_to_sheet([C.KINDS, ...exportRows]);
assert.strictEqual(sheet['!autofilter'], undefined);
assert.strictEqual(sheet['!ref'], 'A1:D4', 'no total row is appended');

async function verifyPaginationAndBatchImport() {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'app.js'), 'utf8').replace(/init\(\);\s*$/, '');
  const context = vm.createContext({
    window: { ReimburCore: C, reimbur: {} }, localStorage: { getItem: () => null },
    console, setTimeout, clearTimeout, fixture: C.clone(trip)
  });
  vm.runInContext(source, context);
  const run = code => vm.runInContext(code, context);
  run(`
    fixture.expenses = Array.from({ length: 25 }, (_, index) => {
      const expense = C.makeExpense('火车');
      expense.invoices = [{ id: C.uuid(), name: index + '.pdf', storedName: 'file-' + index, amount: 100 }];
      return expense;
    });
    C.syncLedger(fixture); state.claims = [fixture]; state.selectedId = fixture.id;
    renderClaim = () => {}; renderAll = () => {}; renderMain = () => {};
    showToast = () => {}; showError = error => { globalThis.lastError = error; };
  `);
  const key = `ledger.${context.fixture.id}`;
  const sequence = () => [...run('renderLedgerCard(fixture)').matchAll(/<td>(\d+)<\/td><td>/g)].map(match => Number(match[1]));
  assert.deepStrictEqual(sequence(), [1, 2, 3, 4, 5], 'new lists default to five rows per page');
  await run(`handleClick({ target: { closest: () => ({ dataset: { action: 'page-next', pageKey: '${key}' } }) } })`);
  assert.deepStrictEqual(sequence(), [6, 7, 8, 9, 10], 'next-page button must update the stored page');
  run(`handleChange({ target: { dataset: { pageSizeKey: '${key}' }, value: '7' } })`);
  assert.deepStrictEqual(sequence(), [1, 2, 3, 4, 5, 6, 7]);
  assert(run('renderLedgerCard(fixture)').includes('票面合计 <strong>¥25.00'), 'totals cover all pages');
  run(`state.pagination['${key}'].page = 4; fixture.expenses.splice(7); C.syncLedger(fixture);`);
  assert.deepStrictEqual(sequence(), [1, 2, 3, 4, 5, 6, 7], 'deleting the last page clamps to a valid page');

  context.mockRaw = Array.from({ length: 5 }, (_, index) => ({ id: C.uuid(), name: index + '.pdf', storedName: String(index), mime: 'application/pdf' }));
  context.mockText = [
    '电子发票 铁路电子客票 发票号码：12345678901234567890 票价 ¥69.00',
    '电子发票 航空运输电子客票行程单 发票号码：12345678901234567891 价税合计 ¥800.00',
    '电子发票 *运输服务*客运服务 发票号码：12345678901234567892 价税合计 ¥38.00',
    '电子发票 住宿服务 发票号码：12345678901234567893 价税合计 ¥300.00',
    '打车行程单 发票号码：12345678901234567892 合计金额 ¥999.00'
  ];
  run(`
    state.claims = [C.createClaim('出差')]; state.selectedId = state.claims[0].id;
    globalThis.removed = [];
    API.saveClaim = async claim => C.clone(claim);
    API.importAttachments = async () => C.clone(mockRaw);
    API.readAttachment = async name => ({ data: [Number(name)] });
    API.deleteAttachment = async name => removed.push(name);
    window.pdfjsLib = {
      GlobalWorkerOptions: {},
      getDocument: ({ data }) => ({ promise: Promise.resolve({
        numPages: 1, getPage: async () => ({ getTextContent: async () => ({ items: [{ str: mockText[data[0]] }] }) })
      }) })
    };
    globalThis.location = { href: 'http://localhost/' };
    globalThis.URL = class { constructor() { this.href = 'worker.js'; } };
  `);
  await run('importIntoLedger()');
  assert.strictEqual(run('globalThis.lastError?.message'), undefined);
  assert.strictEqual(run('C.invoiceCount(getClaim())'), 4);
  assert.strictEqual(run('C.invoiceTotal(getClaim())'), 120700);
  assert.strictEqual(run('C.claimTotal(getClaim())'), 120700);
  assert.strictEqual(run(`getClaim().expenses.find(e => e.kind === '打车').itineraries.length`), 1);
  const beforeFailure = run('JSON.stringify({ ...getClaim(), updatedAt: null })');
  run(`API.readAttachment = async () => { throw new Error('corrupt PDF'); };`);
  await run('importIntoLedger()');
  assert.strictEqual(run('JSON.stringify({ ...getClaim(), updatedAt: null })'), beforeFailure);
  assert.strictEqual(run('removed.length'), 5, 'a failed batch removes every new attachment');
  assert.strictEqual(C.classifyInvoice('普通发票'), null, 'unknown invoices require a type choice');

  const multiInvoiceHTML = run(`(() => {
    const expense = C.makeExpense('火车', 0, '张三');
    expense.invoices = [
      { id: C.uuid(), name: '车票A.pdf', storedName: 'a', amount: 6900, number: '11111111111111111111' },
      { id: C.uuid(), name: '车票B.pdf', storedName: 'b', amount: 7200, number: '22222222222222222222' }
    ];
    return renderTransportTable(fixture, [expense], '火车', 0);
  })()`);
  assert(multiInvoiceHTML.includes('11111111111111111111') && multiInvoiceHTML.includes('22222222222222222222'), 'all invoices must remain visible');
  assert(multiInvoiceHTML.includes('69.00') && multiInvoiceHTML.includes('72.00'), 'all invoice amounts must remain editable');

  run(`
    API.readAttachment = async () => ({ data: new Uint8Array([1,2,3]), mime: 'image/png' });
    API.recognizeImages = async () => '电子发票（铁路电子客票）发票号码：12345678901234567890 出发站：杭州东 到达站：宁波 乘车日期：2026年11月3日 票价：¥69.00';
  `);
  const imageRecognition = await run(`inspectAttachment({ name: 'OCR车票.png', sourceName: 'OCR车票.png', storedName: 'ocr-image' }, '打车')`);
  assert.strictEqual(imageRecognition.suggestedKind, '火车');
  assert.strictEqual(imageRecognition.number, '12345678901234567890');
  assert.strictEqual(imageRecognition.amount, 6900);
  assert.deepStrictEqual(imageRecognition.route, { origin: '杭州', destination: '宁波' });
  assert.deepStrictEqual(imageRecognition.railTimes, { departure: '2026-11-03', arrival: null });

assert.strictEqual(C.invoiceAmount('金额 858.49 税额 51.51\n价税合计（大写）玖佰壹拾圆整\n（小写）\n¥910.00'), 91000);
assert.strictEqual(C.invoiceAmount('价税合计（大写）叁拾伍圆肆角壹分 ¥35.41\n（小写）\n备注'), 3541);
assert.strictEqual(C.invoiceAmount('票价（人民币）：￥1,234.50'), 123450);
assert.strictEqual(C.invoiceAmount('实付金额：88.80元'), 8880);
assert.strictEqual(C.invoiceAmount('票价: X69.00'), 6900);
assert.strictEqual(C.invoiceAmount('价税合计 ¥0.00'), 0);
assert.strictEqual(C.invoiceAmount('单价 ¥99.00\n数量2\n金额198.00 税额5.94'), null);
assert.strictEqual(C.invoiceAmount('价税合计 ¥-35.41'), null);
assert.strictEqual(C.invoiceAmount('价税合计 ¥35.411'), null);
assert.deepStrictEqual(C.trainRoute('出发站：上海虹桥\n到达站：杭州东'), { origin: '上海虹桥', destination: '杭州东' });
assert.deepStrictEqual(C.trainRoute('上海虹桥 → 杭州东'), { origin: '上海虹桥', destination: '杭州东' });
assert.deepStrictEqual(C.trainRoute('上海虹桥\nShanghaihongqiao\nG1234\n杭州东\nHangzhoudong'), { origin: '上海虹桥', destination: '杭州东' });
assert.strictEqual(C.trainRoute('电子发票\n发票号码：12345678\n价税合计¥10.00'), null);
assert.deepStrictEqual(C.railTimes('开票日期：2026-11-02\n乘车日期：2026年10月7日\n开车时间：08:30\n到达时间：2026-10-07 10:35'), { departure: '2026-10-07', arrival: '2026-10-07' });
assert.deepStrictEqual(C.railTimes('2026年10月07日 08:30开'), { departure: '2026-10-07', arrival: null });
assert.deepStrictEqual(C.railTimes('乘车日期：2026-10-07'), { departure: '2026-10-07', arrival: null });
assert.strictEqual(C.railTimes('开票日期：2026-11-02 12:30\n出发地：杭州东\n目的地：宁波'), null);
assert.strictEqual(C.railTimes('出发日期：2026-02-30'), null);
assert.strictEqual(C.invoiceNumber('发票号码：1234 5678 9012 3456 7890', '附件.pdf'), '12345678901234567890');
assert.strictEqual(C.invoiceNumber('订单号：ORDER000002', '行程单.pdf', 'itinerary'), 'ORDER000002');
assert.strictEqual(C.documentRole('电子发票（普通发票）\n备注：另附行程单', '行程单.pdf'), 'invoice');
assert.strictEqual(C.documentRole('高德地图 打车 行 程 单\n底部说明：电子发票另附', '附件.pdf'), 'itinerary');
const recognizedTrain = C.recognizeDocument(
  '电子发票（铁路电子客票）\n发票号码：12345678901234567890\n出发站：上海虹桥\n到达站：杭州东\n乘车日期：2026年10月7日\n票价 ¥69.00',
  '车票.pdf', '打车'
);
assert.strictEqual(recognizedTrain.suggestedKind, '火车');
assert.strictEqual(recognizedTrain.number, '12345678901234567890');
assert.strictEqual(recognizedTrain.amount, 6900);
assert.deepStrictEqual(recognizedTrain.cityRoute, { origin: '上海', destination: '杭州' });
assert.deepStrictEqual(recognizedTrain.railTimes, { departure: '2026-10-07', arrival: null });
const recognizedOCR = C.recognizeDocument(
  '电 子 发 票 ( 铁 路 电 子 客 票 )\n发 票 号 码 : 12345678901234567890\n出 发 站 : 上 海 虹 桥 到 达 站 : 杭 州 东\n乘 车 日 期 : 2026 年 10 月 7 日\n票 价 : X69.00',
  'OCR车票.png', '打车'
);
assert.strictEqual(recognizedOCR.suggestedKind, '火车');
assert.strictEqual(recognizedOCR.number, '12345678901234567890');
assert.strictEqual(recognizedOCR.amount, 6900);
assert.deepStrictEqual(recognizedOCR.cityRoute, { origin: '上海', destination: '杭州' });
assert.deepStrictEqual(recognizedOCR.railTimes, { departure: '2026-10-07', arrival: null });
}

(async () => {
  await verifyPaginationAndBatchImport();
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'reimbur-windows-'));
  const wasm = require.resolve('sql.js/dist/sql-wasm.wasm');
  const SQL = await initSqlJs({ locateFile: () => wasm });
  const db = new SQL.Database();
  db.run('CREATE TABLE claims (id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL, updated_at REAL NOT NULL, payload BLOB NOT NULL)');
  db.run('INSERT INTO claims VALUES (?,?,?,?,?)', [trip.id, trip.title, trip.kind, Date.parse(trip.updatedAt), Buffer.from(JSON.stringify(trip))]);
  const file = path.join(temp, 'reimbur.sqlite3');
  fs.writeFileSync(file, Buffer.from(db.export()));
  const reopened = new SQL.Database(new Uint8Array(fs.readFileSync(file)));
  const value = reopened.exec('SELECT payload FROM claims')[0].values[0][0];
  assert.strictEqual(JSON.parse(Buffer.from(value).toString('utf8')).id, trip.id);
  reopened.close(); db.close(); fs.rmSync(temp, { recursive: true, force: true });

  const app = fs.readFileSync(path.join(__dirname, '..', 'src', 'app.js'), 'utf8');
  const index = fs.readFileSync(path.join(__dirname, '..', 'src', 'index.html'), 'utf8');
  const main = fs.readFileSync(path.join(__dirname, '..', 'electron', 'main.js'), 'utf8');
  const preload = fs.readFileSync(path.join(__dirname, '..', 'electron', 'preload.js'), 'utf8');
  assert(app.includes("data-action=\"preview-summary\""));
  assert(app.includes("data-action=\"export-ledger\""));
  assert(app.includes('record-section') || app.includes('recordsCollapsed'));
  assert(app.includes('formatItineraryCanvas(canvas)'));
  assert(app.includes('C.itineraryPrintCrop('));
  assert(!app.includes('trimCanvasBottom'));
  assert(index.includes('data-view="records"'), 'Windows navigation must expose 全部记录 like macOS');
  assert(index.includes('data-ui-icon="briefcase"') && index.includes('data-ui-icon="utensils"') && index.includes('data-ui-icon="banknote"'));
  assert(app.includes('h2>报销状态分布</h2>') && app.includes('h2>分类统计</h2>'));
  assert(app.includes('recognizeAttachmentImages') && app.includes("API.recognizeImages({ storedName })"));
  assert(main.includes("ipcMain.handle('attachment:ocr'") && main.includes("['chi_sim', 'eng']"));
  assert(preload.includes('recognizeImages:'));
  assert(fs.existsSync(path.join(__dirname, '..', 'electron', 'ocr-lang', 'chi_sim.traineddata.gz')));
  assert(app.includes("iconLabel('download', state.busy ? '正在识别…' : '导入发票')"));
  assert(app.includes("iconLabel('folder', '导出发票')"));
  assert(!app.includes('基本信息与报销明细') && !app.includes('出差费用明细') && !app.includes('左下角文字'));
  console.log('PASS Windows OCR recognition, pagination, mixed invoice import and rollback, business calculations, printing crop, SQLite persistence, XLSX shape, and UI wiring');
})().catch(error => { console.error(error); process.exitCode = 1; });
