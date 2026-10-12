# GOB-22 integrated native Settings capture

Captured the actual SettingsView in a 960×840 NSWindow using `scripts/capture-settings.sh`. AppModel uses temporary history/dictionary storage, an isolated UserDefaults suite, a private pasteboard, synthetic device/diagnostic state, and disabled system services. AI cleanup stays disabled and Keychain inspection is disabled. No microphone capture, credential request, or permission change occurs.

Seven window-only screenshots cover General, Audio, Dictionary, Tone, Post-processing, Overlay, and Diagnostics. The diagnostics timing and pending-engine warning are synthetic, explicitly supplied by the fixture. The capture never screenshots the desktop or another application.

The initial Dictionary screenshot confirms its List collapses inside the settings ScrollView even with three saved terms. This evidence triggered the separately reviewed GOB-18 layout fix; it must be recaptured after integration. Post-processing and Overlay grouped Forms show all controls at this window size. The sidebar tagline in this capture predates the GOB-19 sizing fix.

Shutdown calls the real GoblinApplicationDelegate. Quit is delivered through a run-loop timer: calling AppKit terminate from a Swift MainActor task or a main-dispatch block can starve the delegate's asynchronous reply inside AppKit's nested loop. The final capture run exited normally (owned PID85102); the two earlier hung fixture PIDs were sampled and terminated individually. A common-mode timeout exits the fixture if any capture or termination stalls. No preview remains after the successful run.
