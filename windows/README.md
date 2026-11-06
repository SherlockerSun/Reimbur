# Reimbur 轻记报销 · Windows

Windows 10/11 x64 版本，使用 Electron、SQLite（WASM）、PDF.js 构建。

## 功能

- 出差、餐补、补贴三类本地报销记录，自动保存到 SQLite。
- 首页统计报销天数、报销总额、发票总额和发票数量，并展示月度与审批状态图表。
- 出差支持多人、补助、火车、飞机、打车和住宿；住宿按晚数计算。
- 日历点击或拖动多选日期，回扫可撤销。
- PDF/图片在应用内预览、缩放、拖动、复制和下载。
- 报销清单支持导入、编辑、复制、上传、删除和 XLSX 导出。
- 支持导出发票 ZIP，以及每页两张的打印 DOCX。出差报销单和报销单附件排在发票之前，行程单自动裁切底部空白，火车票重复打印两次。
- 设置默认报销人、部门、出差事由、补助及餐补单价和附件命名格式。

## 数据目录

默认使用 Electron 用户数据目录中的 `reimbur.sqlite3` 和 `Attachments/`。实际路径可在“设置 → 数据与存储”查看并打开。备份前请退出软件，然后复制整个数据目录。

## 开发与打包

```bash
npm install
npm run verify
npm run pack:win
```

在 macOS/Linux 上交叉构建 Windows 安装包时，如 GitHub 下载不稳定，可设置镜像：

```bash
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ \
ELECTRON_BUILDER_BINARIES_MIRROR=https://npmmirror.com/mirrors/electron-builder-binaries/ \
npm run pack:win
```

输出：`../dist/windows/Reimbur-2.0.0-Windows-x64-Setup.exe`。
