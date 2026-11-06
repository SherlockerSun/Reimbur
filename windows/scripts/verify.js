'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
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

(async () => {
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
  assert(app.includes("data-action=\"preview-summary\""));
  assert(app.includes("data-action=\"export-ledger\""));
  assert(app.includes('record-section') || app.includes('recordsCollapsed'));
  assert(app.includes('formatItineraryCanvas(canvas)'));
  assert(app.includes('C.itineraryPrintCrop('));
  assert(!app.includes('trimCanvasBottom'));
  console.log('PASS Windows business calculations, printing crop, SQLite persistence, XLSX shape, and UI wiring');
})().catch(error => { console.error(error); process.exitCode = 1; });
