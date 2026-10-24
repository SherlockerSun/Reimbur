import SwiftUI
import AppKit

enum Palette {
    static let ink = Color(red: 0.12, green: 0.19, blue: 0.25)
    static let teal = Color(red: 0.05, green: 0.46, blue: 0.40)
    static let canvas = Color(red: 0.96, green: 0.97, blue: 0.96)
    static let muted = Color(red: 0.45, green: 0.50, blue: 0.53)
}

struct Card<Content: View>: View {
    var height: CGFloat? = nil
    var fillHeight = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .topLeading)
            .frame(maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink.opacity(0.07), lineWidth: 1))
    }
}

struct SectionLabel: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

struct Metric: View {
    var title: String
    var value: String
    var icon: String
    var emphasis = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.system(size: 11)); Spacer(); Image(systemName: icon) }
                .foregroundStyle(emphasis ? .white.opacity(0.75) : Palette.muted)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                .foregroundStyle(emphasis ? .white : Palette.ink)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(emphasis ? Palette.teal : .white, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LabeledField<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            content
        }
    }
}

struct AmountField: View {
    @Binding var cents: Int64
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text("¥").foregroundStyle(Palette.muted)
            TextField("0.00", text: $text).focused($focused).monospacedDigit()
                .onChange(of: text) { _, new in
                    let ascii = new.filter { "0123456789.".contains($0) }
                    let parts = ascii.split(separator: ".", omittingEmptySubsequences: false)
                    let integer = String((parts.first.map(String.init) ?? "").prefix(9))
                    let clean = integer + (parts.count > 1 ? "." + String(parts[1].prefix(2)) : "")
                    if clean != new { text = clean }
                    cents = Money.parse(clean.hasPrefix(".") ? "0" + clean : clean) ?? 0
                }
        }
        .onAppear { text = Money.input(cents) }
        .onChange(of: cents) { _, new in if !focused { text = Money.input(new) } }
        .onChange(of: focused) { _, new in if !new { text = Money.input(cents) } }
        .accessibilityLabel("金额，人民币元")
    }
}

struct CalendarPicker: View {
    @Binding var selection: Set<String>
    @State private var month: Date
    @State private var frames: [String: CGRect] = [:]
    @State private var paint = CalendarPaintSelection()
    @State private var lastPoint: CGPoint?
    @State private var lastSweep = Date.distantPast
    @State private var coordinateID = UUID()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    init(selection: Binding<Set<String>>) {
        _selection = selection
        _month = State(initialValue: selection.wrappedValue.sorted().first.flatMap(DayKey.date) ?? Date())
    }
    private var first: Date {
        DayKey.calendar.date(from: DayKey.calendar.dateComponents([.year, .month], from: month))!
    }
    private var offset: Int { (DayKey.calendar.component(.weekday, from: first) + 5) % 7 }
    private var count: Int { DayKey.calendar.range(of: .day, in: .month, for: first)!.count }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("上个月")
                Button("今天") { month = Date() }.font(.system(size: 11))
                Button { move(1) } label: { Image(systemName: "chevron.right") }.help("下个月")
            }.buttonStyle(.plain)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day).font(.system(size: 10)).foregroundStyle(Palette.muted).frame(height: 22)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 28) }
                    else {
                        let date = DayKey.calendar.date(byAdding: .day, value: index - offset, to: first)!
                        let key = DayKey.string(date)
                        let selected = selection.contains(key)
                        Text("\(index - offset + 1)").font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .foregroundStyle(selected ? .white : Palette.ink)
                                .background(selected ? Palette.teal : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(DayKey.calendar.isDateInToday(date) ? Palette.teal : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard Date().timeIntervalSince(lastSweep) > 0.3 else { return }
                                if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
                            }
                            .background(GeometryReader { geo in Color.clear.preference(key: CalendarFrames.self, value: [key: geo.frame(in: .named(coordinateID))]) })
                            .help("\(key)，点击选择，长按拖动批量选择")
                            .accessibilityLabel("\(key)\(selected ? " 已选择" : "")").accessibilityAddTraits(.isButton)
                    }
                }
            }
            .coordinateSpace(name: coordinateID)
            .onPreferenceChange(CalendarFrames.self) { frames = $0 }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.22, maximumDistance: 14)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateID)))
                .onChanged { value in
                    if case .second(true, let drag?) = value {
                        if lastPoint == nil { visit(drag.startLocation) }
                        let from = lastPoint ?? drag.startLocation
                        let distance = hypot(drag.location.x - from.x, drag.location.y - from.y)
                        let steps = max(1, Int(distance / 3))
                        for step in 1...steps {
                            let f = CGFloat(step) / CGFloat(steps)
                            visit(CGPoint(x: from.x + (drag.location.x - from.x) * f, y: from.y + (drag.location.y - from.y) * f))
                        }
                        lastPoint = drag.location
                        lastSweep = Date()
                    }
                }
                .onEnded { _ in
                    if lastPoint != nil { lastSweep = Date() }
                    paint = CalendarPaintSelection(); lastPoint = nil
                })
            HStack {
                Text("已选 \(selection.count) 天").foregroundStyle(Palette.teal).fontWeight(.medium)
                Spacer()
                Menu("快捷选择") {
                    Button("选择本月工作日") {
                        for day in 0..<count {
                            let date = DayKey.calendar.date(byAdding: .day, value: day, to: first)!
                            if !DayKey.calendar.isDateInWeekend(date) { selection.insert(DayKey.string(date)) }
                        }
                    }
                    Button("选择整月") {
                        for day in 0..<count { selection.insert(DayKey.string(DayKey.calendar.date(byAdding: .day, value: day, to: first)!)) }
                    }
                    Button("清空所有日期", role: .destructive) { selection.removeAll() }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 11))
        }.foregroundStyle(Palette.ink)
    }
    private func move(_ amount: Int) { month = DayKey.calendar.date(byAdding: .month, value: amount, to: month)! }
}

private struct CalendarFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct CalendarPaintSelection {
    private var visited = Set<String>()
    private var selecting: Bool?
    mutating func visit(_ key: String, selection: inout Set<String>) {
        guard visited.insert(key).inserted else { return }
        if selecting == nil { selecting = !selection.contains(key) }
        if selecting == true { selection.insert(key) } else { selection.remove(key) }
    }
}

extension CalendarPicker {
    fileprivate func visit(_ point: CGPoint) {
        if let key = frames.first(where: { $0.value.contains(point) })?.key { paint.visit(key, selection: &selection) }
    }
}

struct PeopleTagInput: View {
    @Binding var names: [String]
    @State private var input = ""
    @FocusState private var focused: Bool
    private let inputID = "traveler-name-input"
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            HStack(spacing: 6) {
                                Text(name).lineLimit(1)
                                Button { names.removeAll { $0 == name } } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }.buttonStyle(.plain).help("移除\(name)")
                            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 5)
                                .foregroundStyle(Palette.teal).background(Palette.teal.opacity(0.09), in: Capsule())
                        }
                        TextField("输入姓名，回车确认", text: $input).textFieldStyle(.plain)
                            .font(.system(size: 12)).focused($focused).frame(minWidth: 130)
                            .onSubmit {
                                commit()
                                DispatchQueue.main.async { reader.scrollTo(inputID, anchor: .trailing) }
                            }.onChange(of: focused) { _, value in if !value { commit() } }
                            .accessibilityLabel("出差人姓名").id(inputID)
                    }.frame(minWidth: max(0, geometry.size.width - 16), alignment: .leading).padding(.horizontal, 8)
                        .frame(height: 38).contentShape(Rectangle()).onTapGesture { focused = true }
                }
                .onChange(of: focused) { _, value in if value { reader.scrollTo(inputID, anchor: .trailing) } }
            }
        }.frame(height: 38)
            .background(.white, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Palette.teal : Palette.ink.opacity(0.18), lineWidth: focused ? 1.5 : 1))
            .background(OutsideClickObserver(enabled: focused && !input.isEmpty, action: commit))
    }
    private func commit() {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !names.contains(name) { names.append(name) }
        input = ""
    }
}

struct DismissibleOverlay<Content: View>: View {
    var close: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture(perform: close)
                content.frame(width: min(1000, geometry.size.width - 80), height: min(740, geometry.size.height - 80))
                    .background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
                    .contentShape(Rectangle()).onTapGesture {}
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onExitCommand(perform: close)
    }
}

// A click on an unfocusable area (such as the calendar) does not blur a macOS text field.
// Observe local mouse events so a pending name is confirmed on those clicks too.
private struct OutsideClickObserver: NSViewRepresentable {
    var enabled: Bool
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak coordinator = context.coordinator] event in
            if let coordinator, coordinator.enabled, let view = coordinator.view, event.window === view.window,
               !view.convert(view.bounds, to: nil).contains(event.locationInWindow) { coordinator.action?() }
            return event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.action = action
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var enabled = false
        var action: (() -> Void)?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// Measure each card at its natural height, then give both cards the taller height.
struct InfoCalendarRow: Layout {
    private func widths(_ width: CGFloat) -> [CGFloat] { [max(0, width - 310), 294] }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let heights = zip(subviews, widths(width)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: width, height: heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, width) in zip(subviews, widths(bounds.width)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + 16
        }
    }
}
