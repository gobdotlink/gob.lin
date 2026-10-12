import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
expect(InsertionPolicy.text("hello", trailingSpace: true) == "hello ", "append requested trailing space")
expect(InsertionPolicy.text("hello ", trailingSpace: true) == "hello ", "never duplicate trailing whitespace")
expect(InsertionPolicy.text("hello", trailingSpace: false) == "hello", "respect disabled trailing space")
expect(InsertionPolicy.expectedValue(before: "🧌 old", selectedRange: NSRange(location: 3, length: 3), inserted: "new ") == "🧌 new ", "AX ranges use UTF-16, not Swift character indices")
expect(InsertionPolicy.expectedValue(before: "hello", selectedRange: NSRange(location: Int.max, length: 2), inserted: "bad") == nil, "reject out-of-bounds AX range")
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
