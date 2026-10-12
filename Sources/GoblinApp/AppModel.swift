import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let overlay = OverlayController()
    @Published var mascotState: MascotState = .idle
    let history = HistoryModel()
    let permissions = PermissionModel()
    let hotkeys: HotkeyService
    @Published var lastTranscript: String?
    var pasteTranscript: ((String) -> Void)?

    init() {
        hotkeys = HotkeyService(permissions: permissions)
    }

    var canPasteLastTranscript: Bool {
        guard let lastTranscript else { return false }
        return !lastTranscript.isEmpty && pasteTranscript != nil
    }

    func pasteLastTranscript() {
        guard let lastTranscript, canPasteLastTranscript else { return }
        pasteTranscript?(lastTranscript)
    }
}
