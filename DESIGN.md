# gob.lin design

Read this before changing anything a person sees: a window, the overlay, the menu-bar popover, copy, colour, a sprite or motion.

The target picture is `docs/design/mockup.html`. Open it in a browser for exact layout, sizes and copy. This file holds the rules. Where the two disagree, this file wins. New pixel art lives in `docs/design/sprites/`.

## Direction

gob.lin is a native macOS 26 app with a proud pixel goblin living in it. Controls, materials and type are stock Apple, and the goblin carries the personality. Whimsy is **budgeted** by how often a surface appears:

| Surface | Seen | Budget |
|---|---|---|
| Overlay | ~100 times a day | A face, a moving mouth, one hand. Plain words. |
| Menu-bar popover | daily | A goblin portrait and the wordmark in the header. Everything else is stock. |
| Settings, History | weekly | Status sentences in the goblin's voice. No sprites, except on About and Insights. |
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
| neon | `#57E68F` | `#57E68F` | Marks only: the wordmark on dark, the overlay meter and caret, the tagline on dark, the top word of the Insights cloud on dark |
| candle | `#B26B0F` | `#F2A93B` | Stars and milestones |
| case | `#EDECE9` | `#1E1F21` | Settings and History window background |
| plate | `#FBFAF8` | `#2A2B2E` | A grouped section, with a 0.5 pt hairline |
| bubble | `#181A1C` at 92% | same | The overlay, over a blur |
| lights | green `#2FB765`, amber `#F2A417`, red `#E2372D`, off is a hollow ring | same | Status lights |

### Type

- SF Pro for everything, in seven sizes. They live in `GoblinBrand.swift` as `Font` tokens; a page never invents a size.

  | Token | Size | Job |
  |---|---|---|
  | `.capsLabel` | 10 pt semibold, tracked | The small-caps label above a plate |
  | `.meta` | 11 pt | A second line, a footnote, a count |
  | `.status` | 12 pt | A status sentence, text in a small control |
  | `.row` | 13 pt | Body text, row titles, buttons (semibold for a title) |
  | `.cardTitle` | 15 pt semibold | The title of a card, a sheet or a toolbar |
  | `.reading` | 17 pt | Text read at length: a dictation, the first-run prompt |
  | `.hero` | 28 pt bold | First-run headlines |

  Two exceptions: the overlay's live words are 15 pt (`.overlayWords`), and the Insights headline numbers are 48 pt.
- Workbench for the wordmark "gob.lin" only, at sizes that are multiples of 4: 24 pt in the popover header, 48 pt on About.
- VT323 for the tagline `$ sudo autism --unmuted` only. It appears on About and on the last first-run step, nowhere else. `$` and `autism` take the wordmark's colour: moss on light, neon on dark.
- Press Start 2P for the Insights word cloud only. Draw it at its native 8 pt with antialiasing off, then scale by whole numbers on a 2 pt grid, like the sprites.
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
- **`GoblinEyes`, `GazingGoblin`:** the goblin whose eyes follow the pointer over a whole region.
- **`StatusLight`, `StatusRow`:** status lights, and a light with its sentence.
- **`PlateFormStyle`, `CapsHeader`, `Plate`, `RowDisclosureStyle`:** the case-and-plates pages, and disclosure rows that open from anywhere on the row.
- **`InfoButton`, `rowDetail()`:** an explanation behind an ⓘ. `PlateFormStyle` does this for a row label's extra lines and for a section's footer. Mark a line `rowDetail()` to show it under the title, and a section `footerShown` to show its footer under the plate.
- **`SearchField`, `IconButtonLabel`:** the search field and the icon-only menu button for plates and pages.
- **`KeyCap`, `KeyCombo`, `BigKeyCap`:** keys.
- **`InlineDiff`:** the inline diff, over `TextDiff` in GoblinCore.
- **`AppStatus`, `DiagnosticFailure.plainWords`:** the status line and problem copy.
- **`NoticeCopy`:** the overlay's error faces and sentences, in `DictationOverlay.swift`.

### Pixel art

- **Whole-number scales only.** The head is 64 pt or 128 pt. Draw with `.interpolation(.none)`.
- **The whole head always shows.** Nothing overlaps the face, and no container clips it.
- **Hands grip an edge or do a job** (quill, palm), at the head's scale.
- **Frames swap; they never tween.** Panels around the goblin animate; the sprite changes frame.
- **Hide every sprite from VoiceOver.** The words beside it carry the meaning.

| Frame | File | When |
|---|---|---|
| shut | `goblin-shut.png` | Ready, arming, listening with the mouth closed |
| yap | `goblin-yap.png` | Listening with the mouth open |
| look down | `goblin-look.png` | Transcribing |
| squint | `goblin-squint.png` | Cleaning up; no microphone |
| side-eye | `goblin-side.png` | Password field; popover header while something needs attention |
| closed | `goblin-closed.png` | The inserted nod, idle blinks, asleep |
| sheepish | `goblin-sheepish.png` | The goblin's own fault, like failed cleanup. The sweat drop is drawn in. |
| cackle | `goblin-cackle.png` | The first take and milestones only |
| eyes | `goblin-eyes-ahead.png`, `goblin-eyes-<n…nw>.png` | Popover header and About: slit pupils looking ahead or toward the pointer |
| grip hands | `hand-grip.png` | Gripping the top edge of a card or field. Mirror it for the right hand. |
| open palm | `hand-palm.png` | "Not touching that": no microphone, password field |
| quill fist | `hand-quill.png` | Transcribing |
| props | `prop-zz`, `prop-drop`, `prop-candle`, `prop-spark`, `prop-coin` | Asleep, sweat, milestone, celebration |

The first two frames already ship in `Sources/GoblinApp/Assets/`. The rest are in `docs/design/sprites/`. Copy one into Assets when a surface needs it, and run `xcodegen generate` afterwards. The old 7 × 7 fists in `hands.png` are retired once the grip hands land.

The menu-bar icon (`GoblinBrand.menuImage`) is the 22 px goblin in `design/menu-icon/draw.py`, doubled pixel for pixel for Retina. On a light menu bar its edge and the state-dot ring are black. On a dark menu bar the edge and the ring are dropped, and each green is drawn one step lighter, so the bar itself outlines the goblin and the shading doesn't sink into it. Any outline on a dark bar reads as a glow. To change it, edit the map and rerun the script; don't edit the PNGs by hand.

The eyes frames come from `design/goblin-eyes/draw.swift`: `goblin-shut` with a three-pixel slit pupil in each eye and the glow redrawn around it, one frame per compass point. Looking down starts from `goblin-look`, so the lid drops too. To move a slit, edit its table and rerun the script.

### Voice

- The goblin speaks in the first person in errors, empty states, setup and status sentences: "Cleanup took too long, so I typed your words as you said them."
- Controls, titles and menu items use plain Apple title case: "Record New Key…", "Open Settings".
- Each message says what happened and what was kept, in one sentence where one will do.
- Names: **Cleanup** (formerly Post-processing), **Typing it in** (the insertion group), **talk key** (the shortcut), **dictation** (an entry).
- A page header is the title alone. A status row is for state, never for an explanation.
- A row shows one short line under its title when someone needs it to decide: what the control does if the title doesn't say, what it costs, or what leaves the Mac. Keep it to one line. Everything else (how it works, exceptions, reassurance) waits behind the ⓘ beside the title. A group's note goes behind the ⓘ beside its label, unless it is an instruction for using the group, like "Drag to reorder".
- "autism" appears only inside the tagline.

### Craft

- Radii come from `Radius`: 2 (chart squares, swatches, meter bars), 6 (keycaps, text fields, tooltips, chips), 8 (selected and hovered rows, icon tiles), 12 (plates, cards, large fields), 14 (a popover module) and 20 (the overlay bubble).
- Radii are concentric: outer radius = inner radius + padding. The popover is 22 / 14 / 8 (panel, module, row).
- Buttons take their shape from their job. Inside a plate or a row they are regular rounded rectangles. The closing actions of a window or sheet (Cancel, Save, Continue, Done) are 28 pt capsules: `closingActions()`. Buttons on glass, in the popover and the overlay, are capsules too.
- A selected row in a list inside a plate is a moss tint (`GoblinBrand.selection`) at radius 8, and its text keeps its own colours. The window sidebars keep their neutral grey.
- An icon-only menu button on a plate uses `IconButtonLabel`, which draws it at the height of a regular button. A bordered menu button shrinks to its glyph.
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
| hands-free | same | The label reads "Hands-free", with a hint that names the talk key: "tap fn to finish" |
| transcribing | look down, quill | Firm words. Subline: "Transcribing", then "Parakeet · 0:07 of audio" |
| cleaning up | squint | Words with a highlight sweep every 900 ms. Subline: "Cleaning up · Light · Cerebras". Only shown when Cleanup is on. |
| inserted (new) | closed, one nod | A one-line chip: "Typed into Mail · 23 words · 0.59 s". It leaves after 500 ms. |
| cleanup failed | sheepish | "Cleanup took too long, so I typed your words as you said them." Subline: `Cleanup › Cerebras didn't answer within 4.0 s`. Stays 2.5 s; hovering holds it. |
| no microphone | squint, palm | "I can't hear anything. No microphone is connected." The subline holds "Choose Microphone…". Stays until dismissed, or 6 s. |
| microphone silent | same while listening | A line under the header names the cause: muted, volume at zero, or no sound arriving. Device reports warn despite nonzero noise and clear on hardware recovery; a generic silence notice may remain. Sample-only warnings use 5 s before any sound or 15 s after sound and clear when sound returns. Recording continues. |
| new microphone (new) | side-eye | Asks once, when a microphone is seen for the first time: "Lav Receiver just connected. Should I use it for dictation?" Subline: `Audio › new microphone` with Not Now and a moss Use It. If a take is running, or starts while it's showing, it comes back when the take ends. It isn't asked when macOS already switched to the mic and gob.lin is following macOS, since the mic is already in use. Stays 12 s; hovering holds it. Ignoring it leaves the mic under "Only when picked". |
| different microphone | same while listening | When a take uses a different mic from the last one, a quiet line under the header names it: "Using Lav Receiver". If the mic drops out mid-take, the take moves to the next mic in the ranking and the line says so: "Lav Receiver dropped out · now MacBook Pro Microphone". A silence notice replaces it. |
| password field | side-eye, palm | "That's a password field, so I didn't type there." Subline: `Insert › Secure Input is on`. |
| word offer (new) | look down | After a fix the goblin learned from: "Add “panacea” to the dictionary?" Subline: "You fixed “anasia” · gob.lin", Not Now and a moss Add. Like the microphone question, it waits for a running take and comes back after one that interrupts it. Stays 8 s; hovering holds it. Overlay settings can turn it off. |
| word added (new) | closed | A one-line chip: "Added panacea for gob.lin". It leaves after 1.5 s. |
| milestone (new) | cackle, sparkles | Replaces the inserted chip once, at 1k, 10k, 100k and 1M words: "10,000 words yapped." The bubble edge glows candle. Stays 2.5 s. |

Any other error uses the same form: a symbol, one first-person sentence, and an `Area › cause` subline.

Motion: in is opacity 0→1 and y +8→0 over 140 ms with ease-out; out is 120 ms. New words fade in over 80 ms.

### Menu-bar popover

`GoblinApp.swift`. Use `MenuBarExtra` in window style: a 360 pt glass panel. Top to bottom:

1. **Header:** the goblin at 64 pt, whose eyes follow the pointer anywhere over the popover and look ahead when it leaves (side-eye while something needs attention), the wordmark, a status light with a sentence ("Ready · hold fn to talk"), and a ⋯ button. While the goblin has dictionary suggestions, one moss line under the status ("3 new words for gob.lin") opens the Dictionary page.
2. **Problems:** only while true. Each is an amber module with a plain title and sentence (`DiagnosticFailure.plainWords`) and the one button that fixes it (`AppModel.fix(for:)`).
3. **Update:** only when an update is available, with a Restart button.
4. **Microphone:** the microphone in use, a picker in ranked order ending with Edit Ranking…, and press-and-hold "Hold to Test". The mic opens only while it's held and shows the level; nothing is recorded or saved. While a higher-ranked mic is away or the lid has silenced it, the line under the meter says which one is standing in.
5. **Cleanup and Tone** side by side. Clicking Cleanup's circle toggles it; its label opens the level menu.
6. **Search:** a field plus the four latest dictations. Hovering a row shows copy and star. Then "All History".
7. **Footer:** "Paste Last Dictation ⌥⇧⌘V" and "Settings… ⌘,".

The ⋯ menu is a plain menu: Permissions… (with the number that are off), Diagnostics…, Copy Diagnostics, Check for Updates…, About gob.lin, and Quit gob.lin ⌘Q.

Right-clicking or Control-clicking the menu-bar icon opens a native menu instead of the popover: Cancel Dictation ⎋ (only while recording), Paste Last Dictation ⌥⇧⌘V, Settings… ⌘,, then the ⋯ menu. Both menus come from the same lists in `Menu/StatusMenu.swift`.

### Settings

`Sources/GoblinApp/Settings/` and the per-page views.

- **Case and plates:** the window background is the case, and each group is a plate with a 10 pt small-caps label above it.
- **Window chrome:** the sidebar is always visible (no toggle), with the traffic lights inside it. The page title is the window's toolbar title, level with the traffic lights, and the toolbar draws no band, so the case runs to the top of the window. Scroll views use the hard top edge effect, so scrolled content stops at the toolbar and never shows through the title.
- **Status rows:** a group may end with one status row: a light, a sentence, and either a right-aligned detail or one button.
- **Sidebar:** General, Audio, Model, Dictionary, Cleanup, Tone, History (retention only), Overlay, Diagnostics, About, all with SF Symbols. The footer is a status light, "Ready", and the engine and where it runs ("Parakeet v3 · on this Mac").
- **General:**
  - Talk key: a big keycap card with the key, one sentence on how it works, and Record New Key…. Quick picks: fn / Globe, Right ⌥, ⌥ Space. Cancel a take: esc, or the overlay's × when esc is the talk key. A status row for the Globe key setting.
  - Behaviour: Open at login, Click sounds, Add a space after each take.
  - Reduce audio while dictating: independent Pause current media and Mute audio switches. Explain that pause preserves the current player's position, mute lets playback advance, and both can be enabled. Preserve the existing pause preference; mute starts off.
  - Typing it in: the paste-last shortcut with Change…, a status row for the insertion mode and the last insert, and a status row for permissions with Open Setup….
- **Audio:** Microphones is the ranked list. Each row has a light (green in use, amber silenced by the lid, hollow otherwise), the name, and its transport and state, plus a menu with the same moves as dragging. The System Default row is the line: mics above it are used in order, mics below it ("Only when picked") never on their own. A status row names the mic in use and the one it's standing in for.
- **Cleanup:** the switch and level apply as soon as they change; the provider is edited in a sheet and applies on Save.
  - A top plate with the AI cleanup switch and a status row naming where the text goes. Turning it on with an unfinished provider opens the provider sheet, whose button reads Save and Turn On.
  - Provider: one row naming the service, with the model, host (Local and Custom) and "key saved" under it, and Edit…. While the provider can't run, an amber row says what's missing, with Set Up….
  - Style: Level (None, Light, Medium, Coding agent) as a popup, with the level's description under the label. Cloud providers add a “Send text near the cursor” switch, off by default, whose line says what is sent and to whom, with the rest behind its ⓘ; the top status row then says the text near the cursor goes too.
  - Try it: one line of sample text as an **inline diff**. Cut words are struck through on a red tint and added words sit on a green tint, with Run Again. The group's ⓘ holds the timeout note: "Slower than 4 s? I type what you said instead."
  - The provider sheet: Service, Address (Local and Custom only; named services use their own), Model (a free field with a chevron menu of suggested models, then the ones the service lists for the key), Reasoning, API key (masked, "Saved in gob.lin preferences", Remove), the model-list status row with Refresh, and Advanced request options. Every control ends on the same right edge. Cancel and Save.
- **Dictionary:** while there are suggestions, a card above Terms with the look-down goblin at 64 pt gripping its top edge. A title in the goblin's voice ("I found some words in gob.lin"), the budget ("22 of 32 words for gob.lin"), and one row per word with a reason caption ("you fixed “go blin”", "from Package.swift"), Not Now and Add, plus Add All. Nothing is added without a click. A word learned from a fix is also offered once in the overlay; Not Now there is the same as Not Now here. Below it, one plate. Its header is a search field, a ⋯ menu holding Import Words… and a moss Add Term. Under the header the plate splits in two and hugs its content: places on the left, drawn with `SidebarRow` (Everywhere, apps with their icons and a chevron that opens their projects, then Other Projects), and the selected place's words on the right, as a table with Word and Sounds Like columns in SF Pro. Its header has the place, the app icon and a meter ("32 of 32 active") that opens the words in priority order. The selected place is a moss tint. Edit and delete appear on hover, and in the row's context menu.
- **About:** centred.
  - The goblin at 128 pt, whose eyes follow the pointer anywhere over the page, the 48 pt wordmark, the version, and the tagline with a blinking block cursor.
  - Two plates, one above the other: four sentences of lore with three stats (words yapped, dictations, 0 s of audio uploaded), then spec rows (recognition, runs on, model size, languages, network).
  - Check for Updates…, Licences, Data Folder.

### History window

`Sources/GoblinApp/History/`. History is its own window (about 1100 × 720), opened from "All History" in the popover.

- **Sidebar:** Insights, All Dictations, Starred and Warnings, each with a count, then Apps with counts. The filters run in the store query, not on the loaded page. The footer is the week's total: "1,284 words this week. About 23 minutes of typing you didn't do."
- **List:** grouped by day. The selected row is a moss tint. A row is the app icon, app name, time, a two-line preview, the length, a star, and "Not inserted" when it failed.
- **Detail:**
  - The app and title, then the time and length.
  - The text at 17 pt, then playback with a waveform.
  - A fact strip: Words, Tone, Cleanup, Speech model.
  - "537 ms from key-up to text in Mail", above a stacked bar split into Transcribe, Cleanup and Paste.
  - "What you said": the raw transcript, with the words cleanup cut struck through (the same inline diff as the Cleanup page).
  - Re-transcribe and Rewrite under the text. Star, copy and delete sit in the toolbar.
- **Insights:** plates on the case, numbers in monospaced digits, chart bars in moss. A Today / This Week / All Time selector in the toolbar sets the period for the whole page. Only Streak ignores it, because a streak always counts back from today.
  - Summary, headed by the period: Typing saved and Words as two big numbers, the talking time in the goblin's voice ("You talked for 59 minutes. I did all the typing."), and the look-down goblin at 128 pt with its quill, sitting on the plate's divider. Below it: Dictations, Speaking pace and Streak. Typing saved is the time to type the words at 40 words a minute, less the time spent talking.
  - Activity: bars stand on faint full-height tracks, labelled on the current bar and the peak, which is the full-moss bar and bold label when it's the current one. The hour grid is 7 × 24 square cells in four steps of moss. Hovering a bar or a square shows its count. Today is words per hour across the whole plate. This Week is words per day with a dashed average beside When you talk, and ‹ › step a week at a time. All Time is the last 12 months with a dashed average beside When you talk by weekday.
  - What you talked about: the pixel word cloud for the selected period. The side-eye goblin grips the top edge of the biggest word, and smaller goblins and sparks appear only where a gap fits them. The layout is seeded by the day and period, so it doesn't reshuffle on every visit. Hovering a word shows how often you said it.
  - Where I typed: app icon, name, words and share over a thin moss track. Counts and shares use the selected period's words. Then "How I count".
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
   - The goblin, the sentences and the hint sit on the window's centre line, centred in the space above the bottom row.
   - The bottom row: the tagline on the left, on a faint tint, with Open Settings and Done on the right.

## Before you call a UI change done

1. Build and run the signed app with `scripts/build.sh`.
2. Screenshot every surface you changed in light and in dark. Shoot the overlay over a light app and over a dark app. `scripts/capture-settings.sh <folder> [settings|history|popover|onboarding|overlay]` renders every surface from synthetic data without a microphone, and `scripts/check-mascot.sh` checks the overlay's sprite rules.
3. Repeat with Reduce Motion and Increase Contrast on.
4. Check the change against every rule above. Each one either holds, or the pull request says why it doesn't.

Done means every changed surface has light and dark screenshots in the pull request, and no rule is broken without a stated reason.
