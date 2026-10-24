# Reimbur 轻记报销

原生 macOS 报销记录应用，使用 SwiftUI、SQLite、PDFKit，在本机离线运行，无需额外依赖。

## 运行

系统要求：macOS 14 或更新版本。当前提供的构建为 Apple Silicon 版本。

1. 解压 `dist/Reimbur-macOS-arm64.zip`。
2. 双击 `Reimbur.app`，也可以拖入“应用程序”文件夹。
3. 点击“新建出差 / 餐补 / 补助”，默认名称为 `类型报销yyyyMMdd`（例如 `出差报销20261023`），直接点击顶部名称编辑，允许重名；在日历上点击选日期。
4. 在基本信息中填写报销人。出差按费用类型 tab 添加费用，出差补助逐人拆分且无需发票；餐补填写每日单价，按天数计算报销总额；补助无报销日期，在基本信息单独填写报销总额。两类记录均可在“发票附件”批量导入 PDF，自动生成清单，号码和票面金额自动识别、可编辑。
5. 出差如有签字报销单，在费用明细上方上传图片。餐补、补助使用报销清单，右上角图标可导出八列 XLSX。
6. 点击“导出打印文档”生成 DOCX；点击“导出发票”将当前记录全部发票与行程单原件导出为 ZIP。左下角“设置”支持导出所有记录的打印文档、设置默认值和附件命名格式。

首次使用为空数据。修改自动保存；删除记录、费用、报销单图片前会提示确认，发票点击删除即刻移除。

下载地址：[GitHub Releases](https://github.com/SherlockerSun/Reimbur/releases/tag/v1.0.0)。安装包适用于 Apple Silicon，要求 macOS 14 或更新版本。

## 功能

| 功能 | 行为 |
| --- | --- |
| 报销类型 | 出差、餐补、补助；按类型、年/月筛选，搜索标题、人员和备注 |
| 日历 | 点击多选、按下立即拖动扫选、回扫含起点可撤销、跨月保留、整月或本月工作日快捷选择，自动去重计天数 |
| 出差补助 | 逐人拆分，每人每日单价 × 该人本项所选天数，再汇总所有人 |
| 交通 | 火车、飞机、打车；录入本项实际总金额；火车和飞机可选择常用城市或输入任意车站、机场 |
| 多人交通 | 逐人添加独立费用，每笔从姓名名单中选择报销人 |
| 住宿 | 直接填写总价，支持发票金额同步；默认天数减一晚，可单独选入住日期，每个日期计一晚 |
| 餐补 | 所选天数 × 每日单价，固定用途为餐补报销 |
| 补助 | 无报销日期，单独填写总额与用途，发票清单独立统计 |
| 报销清单 | 编辑票据日期、人员、号码、票面金额、报销单金额及明细，批量导入与 XLSX 导出 |
| 独立日期 | 每项补助、餐补、住宿可覆盖主日历日期，例如出差三天、住宿两晚 |
| 发票 | 每项上传多个 PDF（出差补助除外）、应用内预览原件、自动识别票面金额并支持修改、查看份数和页数、点击即删 |
| 行程单 | 打车费用单独上传 PDF 或常见图片，不计入任何发票统计，支持预览、删除及随发票导出 |
| 附件导出 | “导出发票”按发票 / 行程单分类打包 ZIP，原始内容不变，重名自动编号 |
| 汇总 | 每项与整条记录的金额、发票金额、发票数量，以及总额减发票金额的差值；差值允许为负数 |
| 个人明细 | 出差每人费用、金额与发票数；分类清单可切换查看与复制，个人合计与整体一致 |
| 报销单 | PNG、JPEG、HEIC、TIFF、BMP、GIF；多个图片按上传顺序排列 |
| Word 打印 | 标准 `.docx`、A4 每页上下两张，仅包含附件；报销单在本记录发票前，行程单裁切底部空白，火车票连续两份，保留全部 PDF 页面 |
| SQLite | 本地自动保存，独立复制附件，导入失败回滚，写入错误提示 |

“本月工作日”指周一至周五，不判断法定节假日调休，请根据实际情况点击调整。

发票数量按 PDF 文件计算，多页 PDF 计一份，导出包含每一页。图片报销单和打车行程单不计入发票份数与金额。上传时优先读取 PDF 文字中的票面总金额，扫描件使用本机 OCR，支持手动修正，无法识别时请补填。交通、住宿识别后同步费用总额，费用总额仍可手动调整；餐补按天数 × 单价计算，补助报销总额单独填写。两类记录的报销总额与发票总额独立展示，差额用于核对。

## 数据与备份

默认数据目录：`~/Library/Application Support/Reimbur/`，可在左下角“设置 → 数据与存储”查看、复制路径或在 Finder 中打开。

```text
Reimbur/
  reimbur.sqlite3          SQLite 数据库
  reimbur.sqlite3-wal      运行时可能存在的 WAL 日志
  reimbur.sqlite3-shm      运行时可能存在的共享内存文件
  Attachments/            发票、行程单与报销单原件，新附件在 UUID 子目录内以命名规则保存
```

备份时先退出应用，再复制整个文件夹；恢复时也需退出应用并整体还原目录。附件会复制到这里，不依赖原始上传文件的位置。

数据库 schema 版本为 1。`claims` 表存储记录 ID、标题、类型、更新时间及完整 JSON 数据；金额为整数“分”。SQLite 使用 WAL、FULL synchronous。日期使用本地公历 `yyyy-MM-dd` 字符串。

## 开发与打包

需要 Swift 5.9 或以上、macOS 14 或以上的 SDK。仅安装 Xcode Command Line Tools 即可，无需外部 Swift 包或网络服务。

```sh
swift run Reimbur

# 生成当前 Mac 架构的应用，并进行本机 ad hoc 签名
./scripts/build-app.sh
open dist/Reimbur.app

# 校验核心功能与导出，不依赖完整 Xcode 的 XCTest
./scripts/test.sh

# 可选：保留 Word 测试样本和原生界面截图
REIMBUR_QA_DIR="$PWD/output/qa-$(date +%s)" ./scripts/test.sh

# 使用独立数据目录开发
REIMBUR_DATA_DIR="$PWD/output/dev-data" swift run Reimbur
```

测试使用临时数据库，不修改正式数据。

```text
Sources/Reimbur/
  AttachmentFiles.swift 附件命名、号码识别、发票原件 ZIP 导出
  App.swift             入口、侧栏、记录列表
  Dashboard.swift       首页统计图表与年月筛选
  ClaimSummary.swift    清单文字与日期区间汇总
  ClaimEditor.swift     编辑、明细、附件界面
  ExpenseGroupTabs.swift 费用类型长按拖动排序
  SettingsView.swift    常用单价、导出偏好、数据路径及关于
  AttachmentPreview.swift 应用内 PDF、图片预览
  Components.swift      日历、金额输入、界面组件
  Models.swift          模型和金额计算
  Database.swift        SQLite 存取
  ClaimStore.swift      状态管理与文件操作
  WordExporter.swift    PDF 渲染、Word OOXML 打包
  InvoiceLedgerView.swift 餐补、补助可编辑清单
  LedgerExporter.swift  八列 XLSX 清单导出
Sources/CSQLite/        系统 SQLite 桥接
Tests/Verification.swift
scripts/build-app.sh
scripts/test.sh
```

生成 Word 不要求安装 Microsoft Word。PDF 页面转换为高分辨率图片嵌入，保留票面布局；打印可使用 Word 或兼容软件。导出文档不保留 PDF 的可搜索文字及数字签名，PDF 原件会完整保存在附件目录。

此版本为本机开发构建，尚未进行 Apple Developer ID 签名及公证，未包含云同步、多设备协作及发票验真。
