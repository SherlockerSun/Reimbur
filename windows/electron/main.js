const { app, BrowserWindow, ipcMain, dialog, shell, Menu, clipboard, nativeImage } = require('electron');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const initSqlJs = require('sql.js');
const XLSX = require('xlsx');
const archiver = require('archiver');
const {
  Document, Packer, Paragraph, ImageRun, Table, TableRow, TableCell,
  WidthType, AlignmentType, BorderStyle, VerticalAlign
} = require('docx');

let mainWindow = null;
let database = null;
let databasePath = '';
let attachmentRoot = '';
let sqlModulePromise = null;
const execFileAsync = promisify(execFile);

function dataRoot() {
  return process.env.REIMBUR_WINDOWS_DATA_DIR || app.getPath('userData');
}

function uuid() {
  return require('crypto').randomUUID().toUpperCase();
}

function safeStem(value, fallback = '报销记录') {
  const stem = String(value || '').replace(/[<>:"/\\|?*\x00-\x1F]/g, '_').trim().replace(/[. ]+$/g, '');
  return stem || fallback;
}

function sqlWasmPath() {
  const packaged = path.join(process.resourcesPath, 'app.asar.unpacked', 'node_modules', 'sql.js', 'dist', 'sql-wasm.wasm');
  if (fs.existsSync(packaged)) return packaged;
  return path.join(__dirname, '..', 'node_modules', 'sql.js', 'dist', 'sql-wasm.wasm');
}

async function getSql() {
  if (!sqlModulePromise) sqlModulePromise = initSqlJs({ locateFile: () => sqlWasmPath() });
  return sqlModulePromise;
}

async function persistDatabase() {
  if (!database || !databasePath) return;
  const temporary = `${databasePath}.tmp`;
  await fsp.writeFile(temporary, Buffer.from(database.export()));
  await fsp.rename(temporary, databasePath);
}

async function openDatabase() {
  const root = dataRoot();
  attachmentRoot = path.join(root, 'Attachments');
  await fsp.mkdir(attachmentRoot, { recursive: true });
  databasePath = path.join(root, 'reimbur.sqlite3');
  const SQL = await getSql();
  database = fs.existsSync(databasePath)
    ? new SQL.Database(new Uint8Array(await fsp.readFile(databasePath)))
    : new SQL.Database();
  database.run('CREATE TABLE IF NOT EXISTS claims (id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL, updated_at REAL NOT NULL, payload BLOB NOT NULL)');
  database.run('CREATE INDEX IF NOT EXISTS claims_updated ON claims(updated_at DESC)');
  database.run('PRAGMA user_version=1');
  if (!fs.existsSync(databasePath)) await persistDatabase();
}

function listClaims() {
  const result = database.exec('SELECT payload FROM claims ORDER BY updated_at DESC');
  if (!result.length) return [];
  const index = result[0].columns.indexOf('payload');
  return result[0].values.map(row => {
    const value = row[index];
    const text = typeof value === 'string' ? value : Buffer.from(value).toString('utf8');
    return JSON.parse(text);
  });
}

async function saveClaim(payload) {
  const claim = JSON.parse(JSON.stringify(payload));
  claim.updatedAt = new Date().toISOString();
  const blob = Buffer.from(JSON.stringify(claim), 'utf8');
  database.run(
    'INSERT INTO claims(id,title,kind,updated_at,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,kind=excluded.kind,updated_at=excluded.updated_at,payload=excluded.payload',
    [String(claim.id), String(claim.title || ''), String(claim.kind || ''), Date.parse(claim.updatedAt), blob]
  );
  await persistDatabase();
  return claim;
}

async function deleteClaims(ids) {
  database.run('BEGIN IMMEDIATE');
  try {
    for (const id of ids || []) database.run('DELETE FROM claims WHERE id=?', [String(id)]);
    database.run('COMMIT');
    await persistDatabase();
  } catch (error) {
    database.run('ROLLBACK');
    throw error;
  }
}

function insideAttachmentRoot(relative) {
  const resolved = path.resolve(attachmentRoot, String(relative || ''));
  return resolved === attachmentRoot || resolved.startsWith(attachmentRoot + path.sep) ? resolved : null;
}

function mimeFor(file) {
  switch (path.extname(file).toLowerCase()) {
    case '.pdf': return 'application/pdf';
    case '.png': return 'image/png';
    case '.jpg':
    case '.jpeg': return 'image/jpeg';
    case '.webp': return 'image/webp';
    case '.gif': return 'image/gif';
    case '.bmp': return 'image/bmp';
    default: return 'application/octet-stream';
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1120,
    minHeight: 700,
    backgroundColor: '#f4f7fb',
    title: 'Reimbur · 轻记报销',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false
    }
  });
  mainWindow.loadFile(path.join(__dirname, '..', 'src', 'index.html'));
  mainWindow.on('closed', () => { mainWindow = null; });
  if (process.env.REIMBUR_SMOKE_SCREENSHOT) {
    mainWindow.webContents.once('did-finish-load', async () => {
      const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
      try {
        await wait(500);
        const destination = process.env.REIMBUR_SMOKE_SCREENSHOT;
        await fsp.mkdir(path.dirname(destination), { recursive: true });
        await fsp.writeFile(destination, (await mainWindow.webContents.capturePage()).toPNG());
        await mainWindow.webContents.executeJavaScript(`document.querySelector('[data-kind="出差"]').click()`);
        await wait(250);
        await mainWindow.webContents.executeJavaScript(`document.querySelector('[data-action="new-claim"]').click()`);
        await wait(700);
        await mainWindow.webContents.executeJavaScript(`
          const department = document.querySelector('[data-field="department"]');
          if (department) { department.value = '软件部'; department.dispatchEvent(new Event('change', { bubbles: true })); }
          const purpose = document.querySelector('[data-field="tripPurpose"]');
          if (purpose) { purpose.value = '客户项目现场支持'; purpose.dispatchEvent(new Event('change', { bubbles: true })); }
          const traveler = document.getElementById('traveler-input');
          if (traveler) { traveler.value = '张三 李四'; traveler.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); }
        `);
        await wait(700);
        await fsp.writeFile(destination.replace(/\.png$/i, '-claim.png'), (await mainWindow.webContents.capturePage()).toPNG());
        await mainWindow.webContents.executeJavaScript(`
          document.querySelector('[data-action="add-expense"]')?.click();
          setTimeout(() => { document.getElementById('main-content').scrollTo({ top: 720, behavior: 'instant' }); }, 100);
        `);
        await wait(600);
        await fsp.writeFile(destination.replace(/\.png$/i, '-expenses.png'), (await mainWindow.webContents.capturePage()).toPNG());
      } catch (error) {
        console.error('Smoke screenshot failed', error);
      } finally {
        app.quit();
      }
    });
  }
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
}

function makeMenu() {
  return Menu.buildFromTemplate([
    {
      label: '文件',
      submenu: [
        { label: '新建出差报销', accelerator: 'CmdOrCtrl+1', click: () => mainWindow?.webContents.send('menu:new', '出差') },
        { label: '新建餐补报销', accelerator: 'CmdOrCtrl+2', click: () => mainWindow?.webContents.send('menu:new', '餐补') },
        { label: '新建补贴报销', accelerator: 'CmdOrCtrl+3', click: () => mainWindow?.webContents.send('menu:new', '补助') },
        { type: 'separator' },
        { label: '设置', accelerator: 'CmdOrCtrl+,', click: () => mainWindow?.webContents.send('menu:settings') },
        { role: 'quit', label: '退出' }
      ]
    },
    {
      label: '视图',
      submenu: [
        { label: '首页', accelerator: 'CmdOrCtrl+H', click: () => mainWindow?.webContents.send('menu:home') },
        { type: 'separator' },
        { role: 'reload', label: '刷新' },
        { role: 'toggleDevTools', label: '开发者工具' },
        { type: 'separator' },
        { role: 'resetZoom', label: '实际大小' },
        { role: 'zoomIn', label: '放大' },
        { role: 'zoomOut', label: '缩小' }
      ]
    },
    {
      label: '帮助',
      submenu: [{ label: 'GitHub 项目主页', click: () => shell.openExternal('https://github.com/SherlockerSun/Reimbur') }]
    }
  ]);
}

function registerIpc() {
  ipcMain.handle('db:list', () => listClaims());
  ipcMain.handle('claim:save', (_event, claim) => saveClaim(claim));
  ipcMain.handle('claim:delete', (_event, ids) => deleteClaims(ids));
  ipcMain.handle('system:data-path', () => ({ root: dataRoot(), database: databasePath, attachments: attachmentRoot }));
  ipcMain.handle('system:open-data-dir', () => shell.openPath(dataRoot()));
  ipcMain.handle('system:copy', (_event, text) => { clipboard.writeText(String(text || '')); return true; });
  ipcMain.handle('system:open-external', (_event, url) => {
    if (!/^https:\/\//i.test(String(url || ''))) throw new Error('仅支持打开 HTTPS 链接');
    return shell.openExternal(url);
  });

  ipcMain.handle('attachment:import', async (_event, options = {}) => {
    const extensions = options.itineraryOnly
      ? ['pdf', 'png', 'jpg', 'jpeg', 'webp']
      : ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'bmp'];
    const result = await dialog.showOpenDialog(mainWindow, {
      title: options.title || '导入发票',
      properties: ['openFile', 'multiSelections'],
      filters: [{ name: '发票与行程单', extensions }]
    });
    if (result.canceled) return [];
    const imported = [];
    for (const source of result.filePaths) {
      const id = uuid();
      const original = path.basename(source);
      const folder = path.join(attachmentRoot, id);
      await fsp.mkdir(folder, { recursive: true });
      const storedName = `${id}/${original}`;
      await fsp.copyFile(source, path.join(attachmentRoot, storedName));
      imported.push({
        id,
        name: original,
        storedName,
        amount: 0,
        pageCount: 1,
        number: null,
        sourceName: original,
        mime: mimeFor(source)
      });
    }
    return imported;
  });

  ipcMain.handle('attachment:read', async (_event, storedName) => {
    const file = insideAttachmentRoot(storedName);
    if (!file || !fs.existsSync(file)) throw new Error('附件文件不存在，可能已被移动或删除。');
    return { data: await fsp.readFile(file), mime: mimeFor(file), name: path.basename(file) };
  });

  ipcMain.handle('attachment:duplicate', async (_event, storedName) => {
    const source = insideAttachmentRoot(storedName);
    if (!source || !fs.existsSync(source)) throw new Error('原附件文件不存在，无法复制。');
    const id = uuid(), name = path.basename(source), folder = path.join(attachmentRoot, id);
    await fsp.mkdir(folder, { recursive: true });
    const nextStoredName = `${id}/${name}`;
    await fsp.copyFile(source, path.join(attachmentRoot, nextStoredName));
    return { id, storedName: nextStoredName };
  });

  ipcMain.handle('attachment:copy-file', async (_event, storedName) => {
    const file = insideAttachmentRoot(storedName);
    if (!file || !fs.existsSync(file)) throw new Error('附件文件不存在，无法复制。');
    if (/\.(png|jpe?g|webp|bmp|gif)$/i.test(file)) {
      const image = nativeImage.createFromPath(file);
      if (!image.isEmpty()) { clipboard.writeImage(image); return true; }
    }
    if (process.platform === 'win32') {
      const escaped = file.replaceAll("'", "''");
      const script = `Add-Type -AssemblyName System.Windows.Forms; $files = New-Object System.Collections.Specialized.StringCollection; $files.Add('${escaped}'); [System.Windows.Forms.Clipboard]::SetFileDropList($files)`;
      await execFileAsync('powershell.exe', ['-NoProfile', '-STA', '-Command', script], { windowsHide: true });
    } else {
      clipboard.writeText(file);
    }
    return true;
  });

  ipcMain.handle('attachment:delete', async (_event, storedName) => {
    const file = insideAttachmentRoot(storedName);
    if (!file) return false;
    const folder = path.dirname(file);
    await fsp.rm(folder, { recursive: true, force: true });
    return true;
  });

  ipcMain.handle('attachment:export-zip', async (_event, { defaultName, files }) => {
    const result = await dialog.showSaveDialog(mainWindow, {
      title: '导出发票',
      defaultPath: `${safeStem(defaultName)}.zip`,
      filters: [{ name: 'ZIP 压缩包', extensions: ['zip'] }]
    });
    if (result.canceled || !result.filePath) return null;
    await new Promise((resolve, reject) => {
      const output = fs.createWriteStream(result.filePath);
      const archive = archiver('zip', { zlib: { level: 9 } });
      output.on('close', resolve);
      archive.on('error', reject);
      archive.pipe(output);
      const used = new Set();
      for (const item of files || []) {
        const file = insideAttachmentRoot(item.storedName);
        if (!file || !fs.existsSync(file)) continue;
        let name = safeStem(path.basename(item.name || path.basename(file)), '附件');
        const ext = path.extname(path.basename(file));
        if (!path.extname(name)) name += ext;
        let candidate = name, index = 1;
        while (used.has(candidate.toLowerCase())) {
          const suffix = path.extname(name);
          candidate = `${path.basename(name, suffix)}_${index++}${suffix}`;
        }
        used.add(candidate.toLowerCase());
        archive.file(file, { name: candidate });
      }
      archive.finalize();
    });
    return result.filePath;
  });

  ipcMain.handle('ledger:export', async (_event, { defaultName, rows }) => {
    const result = await dialog.showSaveDialog(mainWindow, {
      title: '导出报销清单',
      defaultPath: `${safeStem(defaultName)}-报销清单.xlsx`,
      filters: [{ name: 'Excel 工作簿', extensions: ['xlsx'] }]
    });
    if (result.canceled || !result.filePath) return null;
    const headers = ['序号', '日期', '姓名', '发票号码', '金额（元）', '报销单金额', '明细', '用途'];
    const data = [headers, ...(rows || []).map((row, index) => [
      index + 1,
      row.date || '',
      row.claimant || '',
      row.number || '',
      Number(row.invoiceAmount || 0) / 100,
      Number(row.reimbursementAmount || 0) / 100,
      row.detail || '',
      row.purpose || ''
    ])];
    const worksheet = XLSX.utils.aoa_to_sheet(data);
    worksheet['!cols'] = [7, 14, 14, 27, 15, 15, 24, 24].map(wch => ({ wch }));
    worksheet['!freeze'] = { xSplit: 0, ySplit: 1 };
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet, '报销清单');
    XLSX.writeFile(workbook, result.filePath, { bookType: 'xlsx', compression: true });
    return result.filePath;
  });

  ipcMain.handle('print:docx', async (_event, { defaultName, pages }) => {
    const result = await dialog.showSaveDialog(mainWindow, {
      title: '打印发票',
      defaultPath: `${safeStem(defaultName)}-打印发票.docx`,
      filters: [{ name: 'Word 文档', extensions: ['docx'] }]
    });
    if (result.canceled || !result.filePath) return null;
    const valid = (pages || []).filter(page => page && page.dataUrl);
    const sections = [];
    for (let index = 0; index < valid.length; index += 2) {
      const pair = valid.slice(index, index + 2);
      const rows = pair.map(page => new TableRow({
        children: [new TableCell({
          verticalAlign: VerticalAlign.CENTER,
          margins: { top: 80, bottom: 80, left: 80, right: 80 },
          borders: {
            top: { style: BorderStyle.NONE }, bottom: { style: BorderStyle.NONE },
            left: { style: BorderStyle.NONE }, right: { style: BorderStyle.NONE }
          },
          children: [new Paragraph({
            alignment: AlignmentType.CENTER,
            children: [new ImageRun({
              data: Buffer.from(String(page.dataUrl).split(',')[1] || '', 'base64'),
              transformation: { width: Number(page.width || 690), height: Math.max(120, Math.min(350, Number(page.height || 350))) }
            })]
          })]
        })]
      }));
      sections.push({
        properties: { page: { margin: { top: 360, right: 360, bottom: 360, left: 360 } } },
        children: [new Table({ width: { size: 100, type: WidthType.PERCENTAGE }, rows })]
      });
    }
    if (!sections.length) sections.push({ children: [new Paragraph('没有可打印的附件')] });
    const document = new Document({ sections });
    const buffer = await Packer.toBuffer(document);
    await fsp.writeFile(result.filePath, buffer);
    return result.filePath;
  });

  ipcMain.handle('app:version', () => app.getVersion());
}

app.whenReady().then(async () => {
  await openDatabase();
  registerIpc();
  Menu.setApplicationMenu(makeMenu());
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
}).catch(error => {
  dialog.showErrorBox('Reimbur 启动失败', error.stack || error.message || String(error));
  app.quit();
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('before-quit', () => { try { database?.close(); } catch (_) {} });
