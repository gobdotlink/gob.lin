import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
expect(InsertionPolicy.text("hello", trailingSpace: true) == "hello ", "append requested trailing space")
expect(InsertionPolicy.text("hello ", trailingSpace: true) == "hello ", "never duplicate trailing whitespace")
expect(InsertionPolicy.text("hello", trailingSpace: false) == "hello", "respect disabled trailing space")
expect(InsertionPolicy.expectedValue(before: "🧌 old", selectedRange: NSRange(location: 3, length: 3), inserted: "new ") == "🧌 new ", "AX ranges use UTF-16, not Swift character indices")
expect(InsertionPolicy.expectedValue(before: "hello", selectedRange: NSRange(location: Int.max, length: 2), inserted: "bad") == nil, "reject out-of-bounds AX range")
expect(InsertionPolicy.expectedValue(before: "x 🧌 y", selectedRange: NSRange(location: 2, length: 2), inserted: "🧌") == "x 🧌 y", "identical replacement uses the complete UTF-16 selection")
expect(InsertionPolicy.expectedValue(before: "🧌 hello ", selectedRange: NSRange(location: 3, length: 6), inserted: "hello ") == "🧌 hello ", "identical replacement includes prepared trailing whitespace")
expect(InsertionPolicy.expectedValue(before: "\n", selectedRange: NSRange(location: 0, length: 0), inserted: "hello, my name is Rtim ",
    replacesEmptyLineBreak: true) == "hello, my name is Rtim ", "empty editor placeholder disappears when text is pasted")
expect(InsertionPolicy.expectedValue(before: "\n", selectedRange: NSRange(location: 0, length: 0), inserted: "hello ") == "hello \n", "other editors retain real line breaks")
expect(InsertionPolicy.expectedValue(before: "\n", selectedRange: NSRange(location: 1, length: 0), inserted: "hello ",
    replacesEmptyLineBreak: true) == "\nhello ", "a caret after a newline retains it")
expect(InsertionPolicy.expectedValue(before: "earlier\n", selectedRange: NSRange(location: 0, length: 0), inserted: "hello ",
    replacesEmptyLineBreak: true) == "hello earlier\n", "nonempty editor content is never normalized")
expect(!InsertionPolicy.mayRestoreClipboard(providerRead: true, targetPID: 1, focusedPID: 1,
    before: "hello", expected: "hello", observed: "hello", inserted: "hello", ownedChangeCount: 5, currentChangeCount: 5), "an unchanged value never becomes changed-insertion evidence")
func canRestore(read: Bool = true, focused: Int32 = 1, observed: String? = "hello transcript ", count: Int = 5) -> Bool {
    InsertionPolicy.mayRestoreClipboard(providerRead: read, targetPID: 1, focusedPID: focused,
                                        before: "hello ", expected: "hello transcript ", observed: observed, inserted: "transcript ",
                                        ownedChangeCount: 5, currentChangeCount: count)
}
expect(canRestore(), "only complete target evidence restores")
expect(!canRestore(read: false), "target value alone is insufficient")
expect(!canRestore(observed: "hello "), "clipboard-manager provider read cannot restore")
expect(!canRestore(focused: 2), "never restore after focus changes")
expect(!canRestore(count: 6), "never overwrite a newer clipboard")
expect(!canRestore(observed: nil), "unverifiable apps leave transcript available")
expect(canRestore(observed: "transcript hello "), "a caret reported in another text space still finds the paste")
expect(!canRestore(observed: "hello transcript! "), "a rewritten paste is not evidence")
expect(InsertionPolicy.forwardedRange(of: "transcript ", in: "transcript ") != nil, "a page forwards the paste into an empty field")
expect(InsertionPolicy.forwardedRange(of: "transcript ", in: "transcript transcript ") == nil, "a second copy is not evidence")
// Electron apps paste instead of trusting an Accessibility write, including ones that rename Electron's framework.
let bundles = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-electron-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: bundles) }
func bundle(_ name: String, frameworks: [String] = [], asar: Bool = false, info: [String: Any]? = [:]) throws -> URL {
    let app = bundles.appendingPathComponent("\(name).app"), contents = app.appendingPathComponent("Contents")
    for framework in frameworks {
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/\(framework).framework"), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    if asar { try Data().write(to: contents.appendingPathComponent("Resources/app.asar")) }
    if let info {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }
    return app
}
let editor = try bundle("Editor", frameworks: ["Electron Framework"])
let renamed = try bundle("Renamed", frameworks: ["Codex Framework"],
    info: ["CFBundleIdentifier": "com.example.renamed", "ElectronAsarIntegrity": ["Resources/app.asar": ["algorithm": "SHA256"]]])
let archive = try bundle("Archive", asar: true)
let native = try bundle("Native", frameworks: ["Sparkle"], info: ["CFBundleIdentifier": "com.example.native"])
let bare = try bundle("Bare", info: nil)
expect(InsertionPolicy.isElectronApp(at: editor), "Electron's framework marks an Electron app")
expect(InsertionPolicy.isElectronApp(at: renamed), "a renamed framework is found by Electron's Info.plist marker")
expect(InsertionPolicy.isElectronApp(at: archive), "an app archive marks an Electron app")
expect(!InsertionPolicy.isElectronApp(at: native), "a native app keeps Accessibility writes")
expect(!InsertionPolicy.isElectronApp(at: bare), "a bundle without an Info.plist isn't Electron")
print("Insertion safety checks passed")
