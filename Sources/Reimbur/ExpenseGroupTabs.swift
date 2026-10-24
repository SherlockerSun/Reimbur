import SwiftUI

struct ExpenseGroupTabs: View {
    @Binding var claim: Claim
    @Binding var selection: ExpenseKind?
    @State private var drag: TabDrag?
    @State private var frames: [ExpenseKind: CGRect] = [:]
    @State private var coordinateID = UUID()
    @State private var lastReorder = Date.distantPast
    private let tabWidth: CGFloat = 155

    private struct TabDrag {
        var id = UUID()
        var kind: ExpenseKind
        var centerX: CGFloat
        var grabOffset: CGFloat
        var y: CGFloat
        var slotCenters: [CGFloat]
        var settling = false
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(claim.expenseGroups) { group in
                    tab(group)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ExpenseTabFrames.self, value: [group.kind: geo.frame(in: .named(coordinateID))])
                        })
                        .opacity(drag?.kind == group.kind ? 0 : 1)
                        .onTapGesture { if Date().timeIntervalSince(lastReorder) > 0.3 { selection = group.kind } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selection = group.kind }
                }
            }.padding(.horizontal, 1).padding(.vertical, 6).coordinateSpace(name: coordinateID)
                .onPreferenceChange(ExpenseTabFrames.self) { frames = $0 }
                .overlay(alignment: .topLeading) {
                    if let drag, let group = claim.expenseGroups.first(where: { $0.kind == drag.kind }) {
                        tab(group).scaleEffect(1.025)
                            .shadow(color: Palette.ink.opacity(0.15), radius: 5, y: 2)
                            .offset(x: drag.centerX - tabWidth / 2, y: drag.y)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(coordinateID))
                    .onChanged(updateDrag)
                    .onEnded { _ in finishDrag() })
        }
    }

    private func updateDrag(_ value: DragGesture.Value) {
        if drag == nil {
            guard let (kind, frame) = frames.first(where: { $0.value.contains(value.startLocation) }) else { return }
            drag = TabDrag(kind: kind, centerX: frame.midX, grabOffset: value.startLocation.x - frame.midX,
                           y: frame.minY, slotCenters: frames.values.map(\.midX).sorted())
            selection = kind
        }
        guard var session = drag, !session.settling,
              let first = session.slotCenters.first, let last = session.slotCenters.last else { return }
        session.centerX = min(max(value.location.x - session.grabOffset, first), last)
        drag = session
        lastReorder = Date()
        // Use the fixed slot centers so animated cards cannot trigger repeated swaps.
        if let target = session.slotCenters.indices.min(by: {
            abs(session.slotCenters[$0] - session.centerX) < abs(session.slotCenters[$1] - session.centerX)
        }), claim.expenseGroups[target].kind != session.kind {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) {
                claim.moveExpenseGroup(session.kind, to: target)
            }
        }
    }

    private func finishDrag() {
        guard var session = drag, !session.settling,
              let index = claim.expenseGroups.firstIndex(where: { $0.kind == session.kind }) else { return }
        session.settling = true
        session.centerX = session.slotCenters[index]
        lastReorder = Date()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) { drag = session }
        let id = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            if drag?.id == id { drag = nil }
        }
    }
    private func tab(_ group: ExpenseGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: group.kind.icon); Text(group.kind.rawValue); Spacer()
                Text("\(group.expenses.count) 笔").font(.system(size: 10)).opacity(0.7)
            }
            Text(Money.format(group.total(in: claim))).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(group.kind.acceptsInvoices || group.invoiceCount > 0 ? "\(group.invoiceCount) 份发票" : "无需发票")
                .font(.system(size: 10)).opacity(0.7)
        }.font(.system(size: 11)).padding(14).frame(width: tabWidth)
            .foregroundStyle(selection == group.kind ? Palette.teal : Palette.ink)
            .background(selection == group.kind ? Palette.teal.opacity(0.08) : .white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(drag?.kind == group.kind ? Palette.teal : (selection == group.kind ? Palette.teal.opacity(0.5) : Palette.ink.opacity(0.08)), lineWidth: drag?.kind == group.kind ? 2 : 1))
            .contentShape(Rectangle()).help("点击查看\(group.kind.rawValue)，拖动整个卡片左右排序")
    }
}

private struct ExpenseTabFrames: PreferenceKey {
    static var defaultValue: [ExpenseKind: CGRect] = [:]
    static func reduce(value: inout [ExpenseKind: CGRect], nextValue: () -> [ExpenseKind: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
