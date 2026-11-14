public enum GoblinMetadata {
    public static let name = "gob.lin"
    public static let version = "0.2.34"
    public static let bundleIdentifier = "app.goblin.dictation"
    #if os(iOS)
    static let userAgent = "gob.lin/\(version) (iOS dictation)"
    #else
    static let userAgent = "gob.lin/\(version) (macOS dictation)"
    #endif
}
