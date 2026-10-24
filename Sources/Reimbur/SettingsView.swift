import SwiftUI
import AppKit

struct ExpenseDefaults: Equatable {
    var subsidy: Int64 = 0
    var meal: Int64 = 0
    var travelerNames: [String] = []
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        func amount(_ key: String) -> Int64 { max(0, min(Money.maximumCents, Int64(defaults.integer(forKey: key)))) }
        return Self(subsidy: amount("defaultSubsidy"), meal: amount("defaultMeal"), travelerNames: AppPreferences.travelerNames(in: defaults))
    }
    func price(for kind: ExpenseKind) -> Int64 {
        switch kind { case .subsidy: return subsidy; case .meal: return meal; default: return 0 }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: ClaimStore
    @AppStorage("startupPage") private var startupPage = "home"
    @AppStorage("defaultSubsidy") private var subsidy = 0
    @AppStorage("defaultMeal") private var meal = 0
    @AppStorage("sidebarCaption") private var sidebarCaption = AppPreferences.defaultCaption
    @AppStorage("defaultTravelerNames") private var travelerNames = "[]"
    @AppStorage("invoiceNameFormat") private var invoiceFormat = AttachmentNaming.defaultFormat
    @AppStorage("itineraryNameFormat") private var itineraryFormat = AttachmentNaming.defaultFormat
    @State private var pathCopied = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置").font(.system(size: 29, weight: .semibold))
                    Text("偏好修改自动保存到这台 Mac。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Card {
                    SectionLabel(title: "通用", subtitle: "启动页面与侧边栏显示内容")
                    HStack {
                        Text("启动页面").font(.system(size: 13)); Spacer()
                        Picker("启动页面", selection: $startupPage) {
                            Text("首页").tag("home"); Text("全部记录").tag("records")
                        }.labelsHidden().frame(width: 180)
                    }
                }
                Card {
                    SectionLabel(title: "界面文字", subtitle: "显示在左下角设置按钮上方，最多 \(AppPreferences.captionLimit) 字")
                    HStack {
                        TextField("设置按钮上方文字", text: $sidebarCaption)
                            .onChange(of: sidebarCaption) { _, value in sidebarCaption = AppPreferences.caption(value) }
                        Text("\(sidebarCaption.count) / \(AppPreferences.captionLimit)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                Card {
                    SectionLabel(title: "默认值", subtitle: "用于新建记录或添加费用；已有记录保留当前设置")
                    HStack(alignment: .top, spacing: 24) {
                        LabeledField(title: "默认报销人") {
                            PeopleTagInput(names: Binding(get: { AppPreferences.decodeNames(travelerNames) }, set: { travelerNames = AppPreferences.encodeNames($0) }))
                        }.frame(maxWidth: .infinity)
                        price("出差补助 / 人天", value: $subsidy).frame(width: 170)
                        price("餐补 / 天", value: $meal).frame(width: 170)
                    }
                }
                Card {
                    SectionLabel(title: "附件命名", subtitle: "上传后自动命名；未识别号码时使用原文件名，重名自动添加 _1、_2 等后缀")
                    LabeledField(title: "发票命名格式") { TextField(AttachmentNaming.defaultFormat, text: $invoiceFormat) }
                    LabeledField(title: "行程单命名格式") { TextField(AttachmentNaming.defaultFormat, text: $itineraryFormat) }
                    Text("可用字段：{报销人}、{发票号码}、{行程单号}、{报销名称}、{费用类型}、{原文件名}、{日期}")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    Text("示例：张三12345678901234567890.pdf；格式留空时使用默认格式。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text("行程单无号码时，{发票号码} 使用同笔打车费用唯一的发票号码；无法确定号码时保留原文件名作为字段值。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Card {
                    SectionLabel(title: "打印文档导出", subtitle: "仅导出报销单、发票与行程单，不添加文字说明")
                    Text("每页上下各一张，火车票连续打印两份；行程单自动裁切底部空白，PDF 的全部页面均保留。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack {
                        Text("共 \(store.claims.count) 条记录 · \(store.claims.reduce(0) { $0 + $1.invoiceCount }) 份发票")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button { store.export(store.claims) } label: { Label("导出全部打印文档", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent).disabled(store.claims.isEmpty || store.exporting || !store.ready)
                    }
                }
                Card {
                    SectionLabel(title: "数据与存储", subtitle: "SQLite 本地数据库；发票、行程单与报销单保留独立副本")
                    LabeledField(title: "数据存储路径") {
                        Text(store.root.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Label(store.ready ? "数据库运行正常" : "数据库不可用", systemImage: store.ready ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(store.ready ? Palette.accent : .orange)
                        Spacer()
                        Button(pathCopied ? "已复制路径" : "复制路径") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.root.path, forType: .string); pathCopied = true
                        }
                        Button("在 Finder 中打开") { NSWorkspace.shared.open(store.root) }
                    }
                    Text("备份时先退出软件，再复制整个数据文件夹；恢复时整体还原。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Card {
                    SectionLabel(title: "关于 Reimbur · 轻记报销", subtitle: "版本 \(version) · 原生 macOS 软件")
                    Text("支持 macOS 14 及以上 · SwiftUI / SQLite / PDFKit").font(.system(size: 12))
                    Link("GitHub · github.com/SherlockerSun/Reimbur", destination: URL(string: "https://github.com/SherlockerSun/Reimbur")!)
                        .font(.system(size: 12)).foregroundStyle(Palette.accent)
                    Text("数据仅保存在本机，修改自动保存。票面金额自动识别并支持手动修改，未识别时请补填；行程单不计入发票统计。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: 920).frame(maxWidth: .infinity, alignment: .leading).padding(32).padding(.top, 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func price(_ title: String, value: Binding<Int>) -> some View {
        LabeledField(title: title) {
            AmountField(cents: Binding(get: { Int64(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }))
                .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 38)
                .background(.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.ink.opacity(0.18)))
        }
    }
}
