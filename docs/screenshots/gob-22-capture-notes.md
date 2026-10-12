# Final integrated native UI capture

These images capture feature source `89b7e5fa51e8ccc0df200460ce9e7158c7441fa0`, including the reviewed Settings layout and wordmark fixes. Run `scripts/capture-settings.sh` from the repository to reproduce them on arm64 macOS 26.

The fixture hosts the actual SettingsView in a 960×840 NSWindow. It uses temporary history/dictionary storage, an isolated UserDefaults suite, a private pasteboard, synthetic device/permission/diagnostic state, and disabled system services. Hit testing is disabled so capture cannot invoke settings actions, open files, copy diagnostics, or paste text. Keychain inspection and cleanup requests stay disabled. The configured example endpoint uses the reserved `.invalid` domain. No live recording or permission change occurs.

All ten Settings sections were visually inspected. Source bindings were checked against AppModel's shared child models and the fixture's isolated preferences:

| Section | Capture and visible checks | Bound source |
| --- | --- | --- |
| General | [Shortcuts, feedback sounds, trailing space, permission button](gob-22-settings-general.png) | Shared HotkeyService/TextInsertionService; isolated defaultAppStorage |
| Audio | [System-default picker, level meter, preview disabled pending permission](gob-22-settings-audio.png) | Shared AudioPreviewModel and PermissionModel; `audio.inputDeviceUID` |
| Model | [Candidate visible and picker disabled while benchmark is pending](gob-22-settings-model.png) | Production benchmark placeholder; no adapter supplied |
| Dictionary | [Three rows, aliases, Edit/Delete, Add/Import, footer](gob-22-settings-dictionary.png) | Shared DictionaryModel loaded from temporary versioned JSON |
| Post-processing | [Disabled cleanup, example endpoint/model, empty key, Light, Save](gob-22-settings-rewrite.png) | RewriteSettingsStore using injected defaults; inspectKeychain=false |
| Tone | [Three choices and previews, Formal selected](gob-22-settings-tone.png) | DictationTone.preferenceKey in isolated defaultAppStorage |
| History | [Keep latest 500, 30 days, deletion explanation, Apply](gob-22-settings-history.png) | Shared HistoryModel.retention initialized from isolated JSON preferences |
| Overlay | [Bottom position, complete explanation and Preview control](gob-22-settings-overlay.png) | `overlayPosition` in isolated defaultAppStorage; shared controller |
| Diagnostics | [Pending-model warning, environment, stage timings, recent error, Copy](gob-22-settings-diagnostics.png) | Same shared DiagnosticsModel used by the menu; synthetic 180 ms ASR / 12 ms rewrite |
| About | [Full wordmark/tagline, version, data/log buttons and bundled licences](gob-22-settings-about.png) | GoblinMetadata and GoblinBrand's actual bundled assets |

The full `$ sudo autism --unmuted` tagline is visible throughout. The original collapsed Dictionary capture is preserved as [before](gob-22-settings-dictionary-before.png); the default Dictionary image now shows the fixed list. The fixture asserts that all SettingsSection cases are covered and the three dictionary terms loaded successfully.

[Branding and menu](gob-19-brand-menu-final.png) shows the production GoblinWordmark, the four actual GoblinBrand.menuImage states, and the exact production GoblinMenu view. The build script extracts the menu into the ignored build directory with only its type visibility changed; its content and bindings stay unchanged. The menu is hosted in an inspection window, so this image does not claim to test macOS's MenuBarExtra popup or menu actions.

Five images host the production DictationOverlay with explicit synthetic state: [arming](gob-12-overlay-arming-final.png), [listening](gob-12-overlay-listening-final.png), [transcribing](gob-12-overlay-transcribing-final.png), [polishing](gob-12-overlay-polishing-final.png), and [error](gob-12-overlay-error-final.png). Each state uses a fresh native host; transitions are not exercised by these captures. The waveform and text are supplied by the fixture. These show the native view, goblin/hands assets, captions, and cancel control; they do not demonstrate real capture, recognition, physical display placement, Spaces, or focus behavior.

Every image captures only the owned native window. The desktop and private application windows are excluded. The fixture cleans up its suite/data, stops its AppModel, and requests quit through a run-loop timer using the real GoblinApplicationDelegate. A common-mode timeout prevents a stalled capture from leaving an instance open. The final capture process (owned PID14484) exited normally with status zero and was verified absent afterward.

## Reused overlay host follow-up

An earlier sequential fixture capture omitted the shared `poli` prefix when moving from “polishing your words…” to “polish failed — pasted raw”. Recreating the host was not sufficient evidence to dismiss that observation, because production OverlayController also reuses its host.

The follow-up reuses one NSHostingView for arming → listening → transcribing → polishing → error, preserving the original per-phase window-title timing and 700 ms settling interval. It captures the native window before explicit redraw, recursively marks every native subview as needing layout/display, calls layoutSubtreeIfNeeded/display and window.displayIfNeeded, then allocates a fresh bitmap and separately captures the native window again.

The strict trial's [pre-redraw native window](gob-12-transition-before-redraw.png) was incompletely painted. Both the [fresh post-redraw bitmap](gob-12-transition-after-redraw-bitmap.png) and [post-redraw native window](gob-12-transition-after-redraw-window.png) show the full “polish failed — pasted raw” caption, matching the independent error-state capture. The reused host therefore renders the complete caption after full invalidation; the clipping did not persist through that check. The original missing-prefix symptom was not reproduced exactly, so its precise cause remains unproven. This evidence identifies a paint/snapshot limitation in the automated fixture and does not claim hardware or production transition acceptance.

The capture helper now requests full native layout/display by default before snapshots. Run `scripts/capture-settings.sh .build/overlay-transition-check --transition-only` for the focused comparison; the pre-redraw diagnostic image intentionally bypasses that helper behavior. No product source changed. A subsequent verification run rendered the full caption both before and after redraw. All three follow-up fixture processes (owned PIDs21110, 23385, and 28769) exited normally with status zero and their exact PIDs were verified absent afterward.
