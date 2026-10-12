import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let permissions = PermissionModel()
    let hotkeys: HotkeyService
    let insertion = TextInsertionService()
    @Published var lastTranscript: String?
    var pasteTranscript: ((String) -> Void)?

    init() {
        hotkeys = HotkeyService(permissions: permissions)
        insertion.lastTranscript = { [weak self] in self?.lastTranscript }
        pasteTranscript = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in await self.insertion.insert(text) }
        }
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
