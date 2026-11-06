const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('reimbur', {
  listClaims: () => ipcRenderer.invoke('db:list'),
  saveClaim: claim => ipcRenderer.invoke('claim:save', claim),
  deleteClaims: ids => ipcRenderer.invoke('claim:delete', ids),
  dataPath: () => ipcRenderer.invoke('system:data-path'),
  openDataDir: () => ipcRenderer.invoke('system:open-data-dir'),
  copyText: text => ipcRenderer.invoke('system:copy', text),
  openExternal: url => ipcRenderer.invoke('system:open-external', url),
  importAttachments: options => ipcRenderer.invoke('attachment:import', options),
  readAttachment: storedName => ipcRenderer.invoke('attachment:read', storedName),
  duplicateAttachment: storedName => ipcRenderer.invoke('attachment:duplicate', storedName),
  copyAttachmentFile: storedName => ipcRenderer.invoke('attachment:copy-file', storedName),
  deleteAttachment: storedName => ipcRenderer.invoke('attachment:delete', storedName),
  exportAttachmentZip: payload => ipcRenderer.invoke('attachment:export-zip', payload),
  exportLedger: payload => ipcRenderer.invoke('ledger:export', payload),
  exportPrintDocx: payload => ipcRenderer.invoke('print:docx', payload),
  appVersion: () => ipcRenderer.invoke('app:version'),
  onNew: callback => ipcRenderer.on('menu:new', (_event, kind) => callback(kind)),
  onHome: callback => ipcRenderer.on('menu:home', callback),
  onSettings: callback => ipcRenderer.on('menu:settings', callback)
});
