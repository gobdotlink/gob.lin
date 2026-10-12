import AppKit
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
let originalText = NSPasteboardItem()
originalText.setString("original", forType: .string)
originalText.setString("<b>original</b>", forType: .html)
let originalBinary = NSPasteboardItem()
let binaryType = NSPasteboard.PasteboardType("app.goblin.check.binary")
originalBinary.setData(Data([0, 1, 255]), forType: binaryType)
expect(pasteboard.writeObjects([originalText, originalBinary]), "prepare isolated multi-item clipboard")
let snapshot = ClipboardSnapshot(pasteboard: pasteboard)!
let provider = TranscriptDataProvider(text: "transcript ")
let transcript = NSPasteboardItem()
transcript.setDataProvider(provider, forTypes: [.string])
transcript.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
transcript.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
pasteboard.clearContents()
expect(pasteboard.writeObjects([transcript]), "write lazy transcript")
let owned = pasteboard.changeCount
expect(pasteboard.string(forType: .string) == "transcript ", "provider serves transcript without trimming")
expect(provider.hasBeenRead, "native provider records consumption")
expect(pasteboard.changeCount == owned, "serving promised data preserves ownership count")
expect(!InsertionPolicy.mayRestoreClipboard(providerRead: provider.hasBeenRead, targetPID: 1, focusedPID: 1,
                                            before: "before", expected: "transcript ", observed: "before",
                                            ownedChangeCount: owned, currentChangeCount: pasteboard.changeCount), "simulated clipboard-manager read cannot trigger restore")
expect(snapshot.restore(to: pasteboard), "restore original multi-item clipboard")
let restored = pasteboard.pasteboardItems!
expect(restored.count == 2, "all clipboard items restored")
expect(restored[0].string(forType: .string) == "original", "plain text restored")
expect(restored[0].string(forType: .html) == "<b>original</b>", "HTML preserved")
expect(restored[1].data(forType: binaryType) == Data([0, 1, 255]), "binary data preserved")
expect(KeyboardLayout.pasteKeyCode() != nil, "current keyboard layout exposes Command+V")
print("Native named-pasteboard and current-layout checks passed; general clipboard untouched")
