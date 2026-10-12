import AppKit

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init?(pasteboard: NSPasteboard) {
        let count = pasteboard.changeCount
        var result: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Never overwrite a clipboard whose promised representation cannot be preserved.
                guard let data = item.data(forType: type) else { return nil }
                representations[type] = data
            }
            result.append(representations)
        }
        guard count == pasteboard.changeCount else { return nil }
        items = result
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

/// AppKit does not report who requested the data: a read is necessary, never sufficient evidence.
final class TranscriptDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var read = false
    init(text: String) { self.text = text }
    var hasBeenRead: Bool { lock.lock(); defer { lock.unlock() }; return read }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string else { return }
        item.setString(text, forType: type)
        lock.lock()
        read = true
        lock.unlock()
    }
}
