import SwiftUI
import AppKit

struct ReimbursementColumn: Identifiable {
    var id: String
    var title: String
    var width: CGFloat
    var minimum: CGFloat = 80
    var growth: CGFloat = 0
    var alignment: Alignment = .center
}

enum ReimbursementColumnSizing {
    static func widths(_ columns: [ReimbursementColumn], available: CGFloat, overrides: [String: Double]) -> [CGFloat] {
        let base = columns.map { max($0.minimum, CGFloat(overrides[$0.id] ?? Double($0.width))) }
        let spare = max(0, available - base.reduce(0, +))
        let weight = columns.reduce(CGFloat(0)) { $0 + $1.growth }
        return zip(columns, base).map { column, width in width + (weight > 0 ? spare * column.growth / weight : 0) }
    }
    // A divider redistributes one fixed pair. Its neighbours and the table width stay put.
    static func resize(_ widths: [CGFloat], columns: [ReimbursementColumn], left: Int, delta: CGFloat, maximumDelta: CGFloat = .greatestFiniteMagnitude, minimumDelta: CGFloat = -.greatestFiniteMagnitude) -> [CGFloat] {
        guard left >= 0, left + 1 < columns.count - 1 else { return widths }
        let change = max(max(columns[left].minimum - widths[left], minimumDelta), min(min(widths[left + 1] - columns[left + 1].minimum, maximumDelta), delta))
        var result = widths; result[left] += change; result[left + 1] -= change
        return result
    }
}

struct ReimbursementTable<Row: Identifiable, Cell: View>: View where Row.ID == UUID {
    var columns: [ReimbursementColumn]
    var rows: [Row]
    var rowHeight: (Row) -> CGFloat
    var sort: (String, Bool?) -> Void
    @ViewBuilder var cell: (Row, Int, ReimbursementColumn) -> Cell
    @AppStorage private var storedWidths: Data
    @State private var resizeStart: [CGFloat]?
    @State private var offset: CGFloat = 0
    @State private var sortedColumn: String?
    @State private var ascending: Bool?
    @State private var hovered: UUID?
    @State private var hoveredHeader: String?
    private let headerHeight: CGFloat = 42

    init(id: String, columns: [ReimbursementColumn], rows: [Row], rowHeight: @escaping (Row) -> CGFloat,
         sort: @escaping (String, Bool?) -> Void, @ViewBuilder cell: @escaping (Row, Int, ReimbursementColumn) -> Cell) {
        self.columns = columns; self.rows = rows; self.rowHeight = rowHeight; self.sort = sort; self.cell = cell
        // The revised defaults replace the old, independently stretched column layout.
        _storedWidths = AppStorage(wrappedValue: Data(), "reimbursement.columns.v2.\(id)")
    }
    private var overrides: [String: Double] { (try? JSONDecoder().decode([String: Double].self, from: storedWidths)) ?? [:] }
    private var contentHeight: CGFloat { headerHeight + rows.reduce(0) { $0 + rowHeight($1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GeometryReader { geometry in
                let widths = ReimbursementColumnSizing.widths(columns, available: geometry.size.width, overrides: overrides)
                let operationWidth = widths.last ?? 108
                let viewport = max(1, geometry.size.width - operationWidth)
                let documentWidth = widths.dropLast().reduce(0, +)
                HStack(alignment: .top, spacing: 0) {
                    ThinTableScrollView(width: documentWidth, height: contentHeight, offset: $offset) {
                        tableContent(widths: widths, viewport: viewport).frame(width: documentWidth, height: contentHeight, alignment: .topLeading)
                    }.frame(width: viewport, height: contentHeight)
                    if let column = columns.last {
                        VStack(spacing: 0) {
                            header(column, width: operationWidth)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                cell(row, index, column).frame(maxWidth: .infinity, alignment: .center)
                                    .frame(width: operationWidth, height: rowHeight(row))
                                    .background(rowBackground(row, index: index))
                                    .overlay(alignment: .bottom) { Divider().opacity(0.45) }
                                    .onHover { hovered = $0 ? row.id : nil }
                            }
                        }.frame(width: operationWidth, height: contentHeight, alignment: .top)
                            .overlay(alignment: .leading) { Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: 1) }
                    }
                }.background(.white)
                    .background(TableHeaderHover { point in
                        guard let point, point.y >= 0, point.y < headerHeight, point.x < viewport else {
                            if hoveredHeader != nil { hoveredHeader = nil }; return
                        }
                        let x = point.x + offset
                        var boundary: CGFloat = 0
                        let index = widths.dropLast().firstIndex { width in boundary += width; return x < boundary }
                        let next = index.map { columns[$0].id }
                        if hoveredHeader != next { hoveredHeader = next }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.ink.opacity(0.09)))
                    .overlay(alignment: .bottomLeading) {
                        if documentWidth > viewport + 0.5 {
                            ThinTableScrollbar(contentWidth: documentWidth, viewport: viewport, offset: $offset)
                                .frame(width: viewport, height: 12).offset(y: 12)
                        }
                    }
            }.frame(height: contentHeight)
            Text("拖动实线调整相邻列宽 · 点击表头排序 · 悬浮查看完整内容")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
    private func tableContent(widths: [CGFloat], viewport: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(columns.dropLast().enumerated()), id: \.element.id) { index, column in header(column, width: widths[index]) }
            }.background(Palette.canvas)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    ForEach(Array(columns.dropLast().enumerated()), id: \.element.id) { columnIndex, column in
                        Group {
                            if column.id == "sequence" { Text("\(index + 1)").monospacedDigit().foregroundStyle(Palette.muted).font(.system(size: 11)) }
                            else { cell(row, index, column) }
                        }.frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 10).frame(width: widths[columnIndex], height: rowHeight(row), alignment: .center).clipped()
                    }
                }.background(rowBackground(row, index: index))
                    .overlay(alignment: .bottom) { Divider().opacity(0.45) }
                    .onHover { hovered = $0 ? row.id : nil }.accessibilityIdentifier("table-row-\(index + 1)")
            }
        }.overlay(alignment: .topLeading) {
            ForEach(0..<max(0, columns.count - 2), id: \.self) { index in
                let boundary = widths.prefix(index + 1).reduce(0, +)
                Rectangle().fill(Palette.ink.opacity(0.13)).frame(width: 1)
                    .frame(width: 7, height: contentHeight).contentShape(Rectangle()).offset(x: boundary - 3.5)
                    .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { value in
                        if resizeStart == nil { resizeStart = widths }
                        applyResize(index: index, delta: value.translation.width, viewport: viewport)
                    }.onEnded { value in
                        applyResize(index: index, delta: value.translation.width, viewport: viewport); resizeStart = nil
                    })
                    .help("拖动调整\(columns[index].title)与\(columns[index + 1].title)的列宽")
                    .accessibilityLabel("调整\(columns[index].title)列宽")
            }
        }.contextMenu {
            Button("恢复默认列宽") { storedWidths = Data(); offset = 0 }
        }
    }
    private func applyResize(index: Int, delta: CGFloat, viewport: CGFloat) {
        guard let start = resizeStart else { return }
        let visibleBoundary = start.prefix(index + 1).reduce(0, +) - offset
        let changed = ReimbursementColumnSizing.resize(start, columns: columns, left: index, delta: delta,
                                                       maximumDelta: max(0, viewport - visibleBoundary - 1), minimumDelta: min(0, 1 - visibleBoundary))
        let values = Dictionary(uniqueKeysWithValues: zip(columns, changed).map { ($0.id, Double($1)) })
        storedWidths = (try? JSONEncoder().encode(values)) ?? Data()
    }
    private func rowBackground(_ row: Row, index: Int) -> Color {
        hovered == row.id ? Palette.accent.opacity(0.055) : index.isMultiple(of: 2) ? .white : Palette.canvas.opacity(0.65)
    }
    private func header(_ column: ReimbursementColumn, width: CGFloat) -> some View {
        TableColumnHeader(title: column.title, sortable: column.id != "sequence" && column.id != "operations",
                          direction: sortedColumn == column.id ? ascending : nil, hovering: hoveredHeader == column.id) {
            let next: Bool? = sortedColumn != column.id ? true : ascending == true ? false : nil
            sortedColumn = next == nil ? nil : column.id
            ascending = next
            sort(column.id, next)
        }.frame(width: width, height: headerHeight).background(Palette.canvas)
    }
}

private struct TableColumnHeader: View {
    var title: String
    var sortable: Bool
    var direction: Bool?
    var hovering: Bool
    var action: () -> Void
    var body: some View {
        Group {
            if sortable {
                Button(action: action) {
                    Text(title).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .trailing) {
                            VStack(spacing: 1) {
                                Image(systemName: "chevron.up").foregroundStyle(direction == true ? Palette.accent : Palette.muted.opacity(0.55))
                                Image(systemName: "chevron.down").foregroundStyle(direction == false ? Palette.accent : Palette.muted.opacity(0.55))
                            }.font(.system(size: 8, weight: .bold)).frame(width: 17, height: 23)
                                .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                                .padding(.trailing, 4).opacity(hovering ? 1 : 0)
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("按\(title)排序")
                    .accessibilityValue(direction.map { $0 ? "升序" : "降序" } ?? "默认顺序")
                    .help("点击切换：升序 → 降序 → 默认顺序")
            } else { Text(title).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
    }
}

// Observe the table viewport once, including events delivered to native cell controls.
private struct TableHeaderHover: NSViewRepresentable {
    var moved: (CGPoint?) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.moved = moved }
    final class TrackingView: NSView {
        var moved: (CGPoint?) -> Void = { _ in }
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] event in
                guard let self else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                self.moved(event.window === self.window && self.visibleRect.contains(point) ? point : nil)
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct ThinTableScrollbar: View {
    var contentWidth: CGFloat
    var viewport: CGFloat
    @Binding var offset: CGFloat
    @State private var initialOffset: CGFloat?
    @State private var hovering = false
    var body: some View {
        GeometryReader { geometry in
            if contentWidth > viewport + 0.5 {
                let track = geometry.size.width - 4
                let thumb = max(36, track * viewport / contentWidth)
                let travel = max(1, track - thumb)
                let maximum = contentWidth - viewport
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.04)).frame(height: 4)
                    Capsule().fill(Palette.muted.opacity(0.5)).frame(width: thumb, height: 4)
                        .offset(x: min(max(0, offset), maximum) / maximum * travel)
                }.frame(height: 12).padding(.horizontal, 2)
                    .opacity(hovering || initialOffset != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovering || initialOffset != nil)
                    .contentShape(Rectangle()).onHover { hovering = $0 }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if initialOffset == nil { initialOffset = offset }
                        offset = min(max(0, (initialOffset ?? 0) + value.translation.width / travel * maximum), maximum)
                    }.onEnded { _ in initialOffset = nil })
            }
        }
    }
}

private struct ThinTableScrollView<Content: View>: NSViewRepresentable {
    var width: CGFloat
    var height: CGFloat
    @Binding var offset: CGFloat
    @ViewBuilder var content: Content
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.documentView = NSHostingView(rootView: content)
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator, weak scroll] _ in
            guard let coordinator, let scroll else { return }
            let value = scroll.contentView.bounds.minX
            if abs(value - coordinator.parent.offset) > 0.5 { DispatchQueue.main.async { coordinator.parent.offset = value } }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let host = scroll.documentView as? NSHostingView<Content> else { return }
        host.rootView = content; host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let clamped = min(max(0, offset), max(0, width - scroll.contentView.bounds.width))
        if abs(scroll.contentView.bounds.minX - clamped) > 0.5 { scroll.contentView.scroll(to: NSPoint(x: clamped, y: 0)); scroll.reflectScrolledClipView(scroll.contentView) }
    }
    final class Coordinator {
        var parent: ThinTableScrollView
        var observer: NSObjectProtocol?
        init(_ parent: ThinTableScrollView) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

struct TablePersonField: NSViewRepresentable {
    @Binding var selection: String?
    var names: [String]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.font = .systemFont(ofSize: 11); button.alignment = .center
        button.target = context.coordinator; button.action = #selector(Coordinator.select(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let items = selection == nil || names.isEmpty ? ["未填写"] + names : names
        if button.itemTitles != items { button.removeAllItems(); button.addItems(withTitles: items) }
        button.selectItem(withTitle: selection ?? "未填写")
        button.toolTip = selection ?? "未填写"
        button.setAccessibilityLabel("报销人：" + (selection ?? "未填写"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: 29)
    }
    final class Coordinator: NSObject {
        var parent: TablePersonField
        init(_ parent: TablePersonField) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            let offset = parent.selection == nil || parent.names.isEmpty ? 1 : 0
            let index = sender.indexOfSelectedItem - offset
            parent.selection = parent.names.indices.contains(index) ? parent.names[index] : nil
        }
    }
}

struct TableActionButton: View {
    var title: String
    var icon: String
    var destructive = false
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) { Image(systemName: icon).frame(width: 27, height: 29).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(destructive && hovered ? .red : Palette.muted)
            .background(hovered ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }.help(title).accessibilityLabel(title)
    }
}

struct TableActionPopover<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: (@escaping () -> Void) -> Content
    @State private var showing = false
    var body: some View {
        TableActionButton(title: title, icon: icon) { showing = true }
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) { content { showing = false } }
                    .font(.system(size: 12)).padding(14).frame(minWidth: 150, alignment: .leading)
            }
    }
}

struct TablePlaceField: View {
    @Binding var text: String
    var placeholder: String
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    private let custom = "手动输入…"
    private let places = ["北京", "上海", "广州", "深圳", "杭州", "宁波", "南京", "苏州", "成都", "重庆", "武汉", "西安", "长沙", "郑州", "天津", "青岛", "厦门", "福州", "合肥", "济南", "昆明"]
    private var options: [String] { (text.isEmpty || places.contains(text) ? [] : [text]) + places + [custom] }
    var body: some View {
        TablePersonField(selection: Binding(get: { text.isEmpty ? nil : text }, set: { value in
            if value == custom { draft = text; editing = true }
            else { text = value ?? "" }
        }), names: options)
            .help((text.isEmpty ? placeholder : text) + "\n可选择城市或手动输入任意地点")
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(placeholder).font(.system(size: 12, weight: .semibold))
                    TextField("输入地点", text: $draft).textFieldStyle(.roundedBorder).focused($focused)
                        .onSubmit(commit).accessibilityLabel("手动输入" + placeholder)
                    Button("确定", action: commit).frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(16).frame(width: 250).onAppear { focused = true }
            }
    }
    private func commit() { text = draft; editing = false }
}
