import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var mascotState: MascotState = .idle
    let permissions = PermissionModel()
    @Published var lastTranscript: String?
    var pasteTranscript: ((String) -> Void)?

    var canPasteLastTranscript: Bool {
        guard let lastTranscript else { return false }
        return !lastTranscript.isEmpty && pasteTranscript != nil
    }

    func pasteLastTranscript() {
        guard let lastTranscript, canPasteLastTranscript else { return }
        pasteTranscript?(lastTranscript)
    }
}
