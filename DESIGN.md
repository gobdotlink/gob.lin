# gob.lin design

Read this before changing anything a person sees: a window, the overlay, the menu-bar popover, copy, colour, a sprite or motion.

The target picture is `docs/design/mockup.html`. Open it in a browser for exact layout, sizes and copy. This file holds the rules. Where the two disagree, this file wins. New pixel art lives in `docs/design/sprites/`.

## Direction

gob.lin is a native macOS 26 app with a proud pixel goblin living in it. Controls, materials and type are stock Apple, and the goblin carries the personality. Whimsy is **budgeted** by how often a surface appears:

| Surface | Seen | Budget |
|---|---|---|
| Overlay | ~100 times a day | A face, a moving mouth, one hand. Plain words. |
| Menu-bar popover | daily | A goblin portrait and the wordmark in the header. Everything else is stock. |
| Settings, History | weekly | Status sentences in the goblin's voice. No sprites, except on About. |
| First run, empty states, milestones, About | rare | The full goblin: big sprites, jokes, sparkles and the tagline. |

## Rules

### Appearance

Every window supports light and dark and follows the system. The overlay is the one exception: it's always dark glass, so it reads the same over any app.

Put moss exactly where the design calls for it. A window-wide `.tint` also colours every bordered button and popup on macOS 26, so apply it locally: `.prominent()` for the one primary action, `PlateToggleStyle` for switches, and `.tint(GoblinBrand.moss)` directly on segmented pickers and lists.

### Colour

The values live in `GoblinBrand`. This table is what it must contain.

| Token | Light | Dark | Job |
|---|---|---|---|
| moss | `#2B7D4F` | `#34965F` fill, `#62C78A` text | Every interactive job: primary buttons, switches, links, selection, chart bars |
| neon | `#57E68F` | `#57E68F` | Marks only: the wordmark on dark, the overlay meter and caret, the tagline |
| candle | `#B26B0F` | `#F2A93B` | Stars and milestones |
| case | `#EDECE9` | `#1E1F21` | Settings and History window background |
| plate | `#FBFAF8` | `#2A2B2E` | A grouped section, with a 0.5 pt hairline |
| bubble | `#181A1C` at 92% | same | The overlay, over a blur |
| lights | green `#2FB765`, amber `#F2A417`, red `#E2372D`, off is a hollow ring | same | Status lights |

### Type

- SF Pro for everything, using system text styles.
- Workbench for the wordmark "gob.lin" only, at sizes that are multiples of 4: 16 pt in the popover header, 48 pt on About.
- VT323 for the tagline `$ sudo autism --unmuted` only. It appears on About and on the last first-run step, nowhere else. `$` and `autism` are neon.
- SF Mono for values a person would copy: URLs, model IDs, a masked API key.
- `.monospacedDigit()` on any number that changes: timers, counts, latencies.

### Status lights

A status light is an 8 pt dot plus a word or sentence beside it. The word always carries the meaning, and the colour repeats it.

- Green: ready or done.
- Amber: waiting, or needs you. Add the one button that fixes it.
- Red: broken.
- Hollow: off.

Use them for the popover header status, the Settings sidebar footer, the last row of a settings group, and the first-run steps and setup card. In the setup card only, a 9 pt small-caps label (ON, WAIT, OFF) sits under the dot.

### Building blocks

Reuse these before writing new ones:

- **`GoblinBrand`:** the colour tokens.
- **`Sprite`, `PixelSprite`, `PeekingGoblin`:** frames, whole-number scaling, and the goblin gripping an edge.
- **`StatusLight`, `StatusRow`:** status lights, and a light with its sentence.
- **`PlateFormStyle`, `CapsHeader`, `Plate`, `RowDisclosureStyle`:** the case-and-plates pages, and disclosure rows that open from anywhere on the row.
- **`KeyCap`, `KeyCombo`, `BigKeyCap`:** keys.
- **`InlineDiff`:** the inline diff, over `TextDiff` in GoblinCore.
- **`AppStatus`, `DiagnosticFailure.plainWords`:** the status line and problem copy.
- **`NoticeCopy`:** the overlay's error faces and sentences, in `DictationOverlay.swift`.

### Pixel art

- **Whole-number scales only.** The head is 64 pt or 128 pt, plus 32 pt in the popover header. Draw with `.interpolation(.none)`.
- **The whole head always shows.** Nothing overlaps the face, and no container clips it.
- **Hands grip an edge or do a job** (quill, palm), at the head's scale.
- **Frames swap; they never tween.** Panels around the goblin animate; the sprite changes frame.
- **Hide every sprite from VoiceOver.** The words beside it carry the meaning.

| Frame | File | When |
|---|---|---|
| shut | `goblin-shut.png` | Ready, arming, About, listening with the mouth closed |
| yap | `goblin-yap.png` | Listening with the mouth open |
| look down | `goblin-look.png` | Transcribing |
| squint | `goblin-squint.png` | Cleaning up; no microphone |
| side-eye | `goblin-side.png` | Password field; popover header while something needs attention |
| closed | `goblin-closed.png` | The inserted nod, idle blinks, asleep |
| sheepish | `goblin-sheepish.png` | The goblin's own fault, like failed cleanup. The sweat drop is drawn in. |
| cackle | `goblin-cackle.png` | The first take and milestones only |
| grip hands | `hand-grip.png` | Gripping the top edge of a card or field. Mirror it for the right hand. |
| open palm | `hand-palm.png` | "Not touching that": no microphone, password field |
| quill fist | `hand-quill.png` | Transcribing |
| props | `prop-zz`, `prop-drop`, `prop-candle`, `prop-spark`, `prop-coin` | Asleep, sweat, milestone, celebration |

The first two frames already ship in `Sources/GoblinApp/Assets/`. The rest are in `docs/design/sprites/`. Copy one into Assets when a surface needs it, and run `xcodegen generate` afterwards. The old 7 × 7 fists in `hands.png` are retired once the grip hands land.

The menu-bar icon (`GoblinBrand.menuImage`) is final, including its state dots. Leave it as it is.

### Voice

- The goblin speaks in the first person in errors, empty states, setup and status sentences: "Cleanup took too long, so I typed your words as you said them."
- Controls, titles and menu items use plain Apple title case: "Record New Key…", "Open Settings".
- Each message says what happened and what was kept, in one sentence where one will do.
- Names: **Cleanup** (formerly Post-processing), **Typing it in** (the insertion group), **talk key** (the shortcut), **dictation** (an entry).
- A page header is the title alone. Turn explanatory footnotes into status rows or delete them.
- "autism" appears only inside the tagline.

### Craft

- Radii are concentric: outer radius = inner radius + padding. The popover is 22 / 14 / 8 (panel, module, row), and the overlay bubble is 20.
- Hairlines provide structure: 0.5 pt at 8–14% black or white. Shadows provide elevation: layered and soft.
- Motion animates transform and opacity only. Enter with ease-out in 120–200 ms, and exit faster than you enter. Scale from 0.94 or more, never from 0. Keyboard-triggered, high-frequency actions don't animate.
- Under Reduce Motion, keep the fades, drop the movement, and keep the sprite frame swaps.
- The whole visible shape of a control is its click target. Plain-styled buttons, menus and rows get a `contentShape` that covers their padding, and a popover tile that opens a menu is clickable edge to edge.

## Surfaces

### Overlay

`Sources/GoblinApp/Overlay/`. It should be **quiet**: fast, legible, and the same size in every phase that has words.

- **Placement:** the bottom-right corner, 16 pt in from the screen edge and 16 pt above the Dock. The Top setting means top-right, 16 pt below the menu bar. If the focused caret is inside the corner zone at key-down, mirror everything to the left corner (sprite flipped too) before showing. Once visible, it never moves.
- **Layout:** a speech bubble about 404 pt wide, with the goblin at 128 pt beside it, bottoms aligned, 12 pt apart. A 10 × 16 pt tail on the bubble points at the goblin's mouth.
- **Bubble:**
  - Header row: a 5-bar neon meter, the phase label (12 pt semibold, 58% white), the timer (38% white) and a 24 pt × button.
  - Words: 15/21 pt. Firm words are 94% white and tentative words 42%. A neon caret shows while listening.
  - The bubble grows one line at a time, up to four. Older lines scroll under a 14 pt top fade.
- **Subline:** optional, below a 0.5 pt divider, 12 pt at 50% white. A bold label sits on the left and the detail on the right. Errors use the form `Area › cause`.

| Phase | Face, hand | Bubble |
|---|---|---|
| arming | shut | Compact: idle meter, "Warming up the mic…", esc |
| listening | shut and yap on mic level (with hysteresis, at most 12 fps) | Header plus live words |
| hands-free | same | The label reads "Hands-free", with a hint: "tap fn to finish" |
| transcribing | look down, quill | Firm words. Subline: "Transcribing", then "Parakeet · 0:07 of audio" |
| cleaning up | squint | Words with a highlight sweep every 900 ms. Subline: "Cleaning up · Light · Cerebras". Only shown when Cleanup is on. |
| inserted (new) | closed, one nod | A one-line chip: "Typed into Mail · 23 words · 0.59 s". It leaves after 500 ms. |
| cleanup failed | sheepish | "Cleanup took too long, so I typed your words as you said them." Subline: `Cleanup › Cerebras didn't answer within 4.0 s`. Stays 2.5 s; hovering holds it. |
| no microphone | squint, palm | "I can't hear anything. No microphone is connected." The subline holds "Choose Microphone…". Stays until dismissed, or 6 s. |
| password field | side-eye, palm | "That's a password field, so I didn't type there." Subline: `Insert › Secure Input is on`. |
| milestone (new) | cackle, sparkles | Replaces the inserted chip once, at 1k, 10k, 100k and 1M words: "10,000 words yapped." The bubble edge glows candle. Stays 2.5 s. |

Any other error uses the same form: a symbol, one first-person sentence, and an `Area › cause` subline.

Motion: in is opacity 0→1 and y +8→0 over 140 ms with ease-out; out is 120 ms. New words fade in over 80 ms.

### Menu-bar popover

`GoblinApp.swift`. Use `MenuBarExtra` in window style: a 360 pt glass panel. Top to bottom:

1. **Header:** the goblin at 32 pt (side-eye while something needs attention), the wordmark, a status light with a sentence ("Ready · hold fn to talk"), and a ⋯ button.
2. **Problems:** only while true. Each is an amber module with a plain title and sentence (`DiagnosticFailure.plainWords`) and the one button that fixes it (`AppModel.fix(for:)`).
3. **Update:** only when an update is available, with a Restart button.
4. **Microphone:** a picker plus press-and-hold "Hold to Test". The mic opens only while it's held and shows the level; nothing is recorded or saved.
5. **Cleanup and Tone** side by side. Clicking Cleanup's circle toggles it; its label opens the level menu.
6. **Search:** a field plus the four latest dictations. Hovering a row shows copy and star. Then "All History".
7. **Footer:** "Paste Last Dictation ⌥⇧⌘V" and "Settings… ⌘,".

The ⋯ menu is a plain menu: Permissions… (with the number that are off), Diagnostics…, Copy Diagnostics, Check for Updates…, About gob.lin, and Quit gob.lin ⌘Q.

### Settings

`Sources/GoblinApp/Settings/` and the per-page views.

- **Case and plates:** the window background is the case, and each group is a plate with a 10 pt small-caps label above it.
- **Window chrome:** the sidebar is always visible (no toggle), with the traffic lights inside it. The page title is the window's toolbar title, level with the traffic lights, and the toolbar draws no band, so the case runs to the top of the window.
- **Status rows:** a group may end with one status row: a light, a sentence, and either a right-aligned detail or one button.
- **Sidebar:** General, Audio, Model, Dictionary, Cleanup, Tone, History (retention only), Overlay, Diagnostics, About, all with SF Symbols. The footer is a status light, "Ready", and the engine and where it runs ("Parakeet v3 · on this Mac").
- **General:**
  - Talk key: a big keycap card with the key, one sentence on how it works, and Record New Key…. Quick picks: fn / Globe, Right ⌥, ⌥ Space. Cancel a take: esc. A status row for the Globe key setting.
  - Behaviour: Open at login, Click sounds, Pause media while dictating, Add a space after each take.
  - Typing it in: the paste-last shortcut with Change…, a status row for the insertion mode and the last insert, and a status row for permissions with Open Setup….
- **Cleanup:**
  - A top plate with the AI cleanup switch and a status row naming where the text goes.
  - Provider: Service, Address, Model (a free field plus a "Suggested" menu), and API key (masked, "Saved in your Keychain", Replace…).
  - Style: Level (None, Light, Medium) and Reasoning.
  - Try it: one line of sample text as an **inline diff**. Cut words are struck through on a red tint and added words sit on a green tint, with Run Again, plus an amber row: "Slower than 4 s? I type what you said instead."
- **About:** centred.
  - The goblin at 128 pt, the 48 pt wordmark, the version, and the tagline with a blinking block cursor.
  - Two plates: four sentences of lore with three stats (words yapped, dictations, 0 s of audio uploaded), and spec rows (recognition, runs on, model size, languages, network).
  - Check for Updates…, Licences, Data Folder.

### History window

`Sources/GoblinApp/History/`. History is its own window (about 1100 × 720), opened from "All History" in the popover.

- **Sidebar:** Insights, All Dictations, Starred and Warnings, each with a count, then Apps with counts. The filters run in the store query, not on the loaded page. The footer is the week's total: "1,284 words this week. About 23 minutes of typing you didn't do."
- **List:** grouped by day. A row is the app icon, app name, time, a two-line preview, the length, a star, and "Not inserted" when it failed.
- **Detail:**
  - The app and title, then the time and length.
  - The text at 17 pt, then playback with a waveform.
  - A fact strip: Words, Tone, Cleanup, Speech model.
  - "537 ms from key-up to text in Mail", above a stacked bar split into Transcribe, Cleanup and Paste.
  - "What you said": the raw transcript, with the words cleanup cut struck through (the same inline diff as the Cleanup page).
  - Re-transcribe and Rewrite under the text. Star, copy and delete sit in the toolbar.
- **Insights:** plates on the case, numbers in monospaced digits, chart bars in moss.
- **Empty:** the closed goblin at 128 pt with Zz, then "Nothing to snitch on yet." and "Hold fn and say something. I'll keep the receipts."
- **Problems:** save errors and unsaved dictations are amber status plates with one action each.

### First run

`Sources/GoblinApp/Permissions/OnboardingView.swift`. One 660 pt window, light or dark, with a step bar of lights: Permissions, Talk key, First take, then the finale.

1. **Permissions:** "Two switches, then you can talk." Match the count to the permissions `PermissionModel` requests; today that's Microphone and Accessibility.
   - The setup plate has one row per permission: a light with a label, a symbol, the name, one line on why, and the action.
   - Only the current row gets the moss tint and the primary button. While the person is in System Settings, an amber line with animated dots reads "Waiting for System Settings. Flip gob.lin on, then come back. I'll notice."
   - The shut goblin at 128 pt grips the plate's top edge.
   - The existing failure and revocation explanations become amber status rows.
2. **Talk key:** the General keycap card on its own, plus a light that turns green when the key is pressed.
3. **First take:** "Say something." and a line to read aloud: "The goblin types faster than I do." When the words land, the field gets a moss ring and the result reads "Nailed it. 7 words in 0.21 s, right where your cursor was." The cackle goblin at 64 pt grips the field.
4. **Finale:** "You're hired."
   - The cackle goblin at 128 pt with sparkles and coins. They burst at 1× then 2× and fade over 600 ms; this is the app's one long animation.
   - The timing sentence, the field with what they said, and a menu-bar hint: "That's me, top right."
   - The tagline strip, then Open Settings and Done.

## Before you call a UI change done

1. Build and run the signed app with `scripts/build.sh`.
2. Screenshot every surface you changed in light and in dark. Shoot the overlay over a light app and over a dark app. `scripts/capture-settings.sh <folder> [settings|history|popover|onboarding|overlay]` renders every surface from synthetic data without a microphone, and `scripts/check-mascot.sh` checks the overlay's sprite rules.
3. Repeat with Reduce Motion and Increase Contrast on.
4. Check the change against every rule above. Each one either holds, or the pull request says why it doesn't.

Done means every changed surface has light and dark screenshots in the pull request, and no rule is broken without a stated reason.
