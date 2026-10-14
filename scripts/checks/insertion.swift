import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
expect(InsertionPolicy.text("hello", trailingSpace: true) == "hello ", "append requested trailing space")
expect(InsertionPolicy.text("hello ", trailingSpace: true) == "hello ", "never duplicate trailing whitespace")
expect(InsertionPolicy.text("hello", trailingSpace: false) == "hello", "respect disabled trailing space")
expect(InsertionPolicy.expectedValue(before: "🧌 old", selectedRange: NSRange(location: 3, length: 3), inserted: "new ") == "🧌 new ", "AX ranges use UTF-16, not Swift character indices")
expect(InsertionPolicy.expectedValue(before: "hello", selectedRange: NSRange(location: Int.max, length: 2), inserted: "bad") == nil, "reject out-of-bounds AX range")
expect(InsertionPolicy.expectedValue(before: "x 🧌 y", selectedRange: NSRange(location: 2, length: 2), inserted: "🧌") == "x 🧌 y", "identical replacement uses the complete UTF-16 selection")
expect(InsertionPolicy.expectedValue(before: "🧌 hello ", selectedRange: NSRange(location: 3, length: 6), inserted: "hello ") == "🧌 hello ", "identical replacement includes prepared trailing whitespace")
expect(!InsertionPolicy.mayRestoreClipboard(providerRead: true, targetPID: 1, focusedPID: 1,
    before: "hello", expected: "hello", observed: "hello", ownedChangeCount: 5, currentChangeCount: 5), "an unchanged value never becomes changed-insertion evidence")
func canRestore(read: Bool = true, focused: Int32 = 1, observed: String? = "hello transcript ", count: Int = 5) -> Bool {
    InsertionPolicy.mayRestoreClipboard(providerRead: read, targetPID: 1, focusedPID: focused,
                                        before: "hello ", expected: "hello transcript ", observed: observed,
                                        ownedChangeCount: 5, currentChangeCount: count)
}
expect(canRestore(), "only complete target evidence restores")
expect(!canRestore(read: false), "target value alone is insufficient")
expect(!canRestore(observed: "hello "), "clipboard-manager provider read cannot restore")
expect(!canRestore(focused: 2), "never restore after focus changes")
expect(!canRestore(count: 6), "never overwrite a newer clipboard")
expect(!canRestore(observed: nil), "unverifiable apps leave transcript available")
print("Insertion safety checks passed")
