# Focused-app text insertion

`TextInsertionService.insert(_:)` is the native pipeline entry. Accessibility writes `AXSelectedText` first when the focused control exposes it as settable. A timeout or ambiguous write failure never triggers a second insertion. Unsupported writes fall back to paste. Secure Input and accessible secure text fields reject insertion.

Paste resolves the V key with `UCKeyTranslate` using the active layout's Command map (including Dvorak-QWERTY Command layouts). All synthetic events post on the main actor; Command is held for 100 ms and always released, including cancellation. This hold is keyboard-event sequencing, never a clipboard-restore delay. Synthetic events are tagged so gob.lin's own modifier hotkey cannot react to its Cmd+V.

The entire previous clipboard is copied, preserving multiple items and data representations. If a promised representation cannot be read, or the clipboard changes during snapshotting, insertion stops before overwriting it. The transcript uses a lazy `NSPasteboardItemDataProvider` with transient/concealed markers. Providers stay alive while the transcript remains available.

**A provider callback does not identify the consumer.** Clipboard managers can read first. Automatic restoration therefore requires all of: the provider was read, the original target remains focused, that target's accessible value exactly matches the expected replacement at its original UTF-16 selection, the value actually changed, and the pasteboard change count is still owned by this transaction. No arbitrary reader or elapsed delay can restore it. A three-second maximum only abandons verification. If confirmation is unavailable, gob.lin leaves the transcript on the clipboard and retains the original contents in memory for the explicit **Restore previous clipboard** menu/settings action. Recover those contents before quitting; recovery is not persisted to disk.

New pastes while the unverified transcript still owns the clipboard carry forward the original recovery snapshot. A newer clipboard change is never automatically overwritten. The menu and global ⌘⌥⇧V shortcut paste the last completed transcript; the engine pipeline must supply that transcript. The trailing-space preference defaults on and does not duplicate existing whitespace.

| App family | Strategy and limitation |
| --- | --- |
| Notes and standard Cocoa editors | Accessibility insertion where supported; otherwise verified paste |
| Terminal / Ghostty | Paste only, avoiding repeated direct typing; terminal AX content often cannot confirm consumption |
| Paseo / VS Code / Cursor / Slack | Paste handles Electron editing; exact AX evidence is used only when exposed |
| Dia / Chrome / Arc | Paste preserves browser input handling; address bars may normalize trailing whitespace and therefore require explicit recovery |
| Remote desktop / VNC / AnyDesk / TeamViewer | Paste only; local AX cannot confirm remote consumption, so automatic recovery is disabled |
| No focused AX control | Paste into the same foreground app; no automatic recovery without target text evidence |

Run `bash scripts/check-insertion.sh` for safety assertions: UTF-16 selection replacement, trailing spaces, no restoration on a clipboard-manager read, focus changes or clipboard ownership changes. `bash scripts/check-native-insertion.sh` exercises a real isolated named pasteboard with lazy data, multiple items, HTML and binary data; it checks the active layout without touching the general clipboard. End-to-end target-app acceptance across every named app and Dvorak/AZERTY still needs an interactive session with those apps/layouts. No actual recognizer is wired before the benchmark.
