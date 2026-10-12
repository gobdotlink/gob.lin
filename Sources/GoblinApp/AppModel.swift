import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    let overlay = OverlayController()
    @Published var mascotState: MascotState = .idle
    let history = HistoryModel()
    let permissions = PermissionModel()
    let hotkeys: HotkeyService
    let insertion = TextInsertionService()
    @Published var settingsSelection: SettingsSection? = .general
    @Published var lastTranscript: String?
    private var subscriptions: Set<AnyCancellable> = []
    var pasteTranscript: ((String) -> Void)?

    init() {
        hotkeys = HotkeyService(permissions: permissions)
        for child in [permissions.objectWillChange, hotkeys.objectWillChange, insertion.objectWillChange, history.objectWillChange] {
            child.sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }.store(in: &subscriptions)
        }
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
