import SwiftUI

enum RecordPreviewRequest {
    case summary(Claim, String?)
    case tripForm(Claim)
}

struct WorkspacePreviewLayer: View {
    @EnvironmentObject private var store: ClaimStore
    var body: some View {
        ZStack {
            if let request = store.preview {
                DismissibleOverlay(close: store.dismissPreview) {
                    AttachmentPreview(request: request, close: store.dismissPreview).id(request.id)
                }
            } else if let request = store.recordPreview {
                DismissibleOverlay(close: store.dismissPreview) {
                    switch request {
                    case let .summary(claim, personID):
                        ClaimTextPreview(claim: claim, initialPersonID: personID, close: store.dismissPreview)
                    case let .tripForm(claim):
                        TripFormPreview(claim: claim, close: store.dismissPreview)
                    }
                }
            } else {
                AttachmentHoverPreviewLayer(session: store.hoverPreview).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
