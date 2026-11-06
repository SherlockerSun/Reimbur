import SwiftUI

struct ExpenseFileActions {
    var upload: (UUID, ExpenseAttachmentRole) -> Void = { _, _ in }
    var open: (Attachment) -> Void = { _ in }
    var hover: (Attachment, NSPoint?) -> Void = { _, _ in }
    var rename: (Attachment, String, UUID) -> Void = { _, _, _ in }
    var remove: (Attachment, UUID) -> Void = { _, _ in }
    var move: (Attachment, UUID, UUID) -> Void = { _, _, _ in }
    var duplicateExpense: (UUID) -> Void = { _ in }
    var duplicateLedgerRow: (UUID) -> Void = { _ in }
    var removeLedgerRow: (UUID) -> Void = { _ in }
    var replaceLedgerInvoice: (UUID) -> Void = { _ in }
}

struct InvoiceFileCell: View {
    var attachment: Attachment
    var expenseID: UUID
    var actions: ExpenseFileActions
    var body: some View {
        HStack(spacing: 7) {
            Button { actions.open(attachment) } label: {
                Image(systemName: "doc.richtext").foregroundStyle(Palette.accent).frame(width: 22, height: 29)
            }.buttonStyle(.plain).help("预览 " + attachment.name).accessibilityLabel("预览 " + attachment.name)
            EditableAttachmentName(attachment: attachment, centered: true) { actions.rename(attachment, $0, expenseID) }
        }.frame(maxWidth: .infinity, alignment: .center).frame(height: 32)
            .background(AttachmentHoverTracking { actions.hover(attachment, $0) })
            .contextMenu { Button("预览") { actions.open(attachment) } }
    }
}
