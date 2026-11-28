# gob.lin design

Read this before changing anything a person sees: a window, the overlay, the menu-bar popover, copy, colour, a sprite or motion.

The target picture is `docs/design/mockup.html`. Open it in a browser for exact layout, sizes and copy. This file holds the rules. Where the two disagree, this file wins. New pixel art lives in `docs/design/sprites/`.

## Direction

gob.lin is a native macOS 26 app with a proud pixel goblin living in it. Controls, materials and type are stock Apple, and the goblin carries the personality. Whimsy is **budgeted** by how often a surface appears:

| Surface | Seen | Budget |
|---|---|---|
| Overlay | ~100 times a day | A face, a moving mouth, one hand. Plain words. |
| Sidekick | during a recorded meeting | The overlay's budget: a face, plus the quill while a mark is written down. |
| Menu-bar popover | daily | A goblin portrait and the wordmark in the header. Everything else is stock. |
| Settings, History, Meetings | weekly | Status sentences in the goblin's voice. No sprites, except on About, Insights and the Hoard. |
| First run, setup sheets, empty states, treasures, About | rare | The full goblin: big sprites, jokes, sparkles and the tagline. |

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
| candle | `#B26B0F` (`#8F5409` for small text) | `#F2A93B` | Stars, treasures and the Hoard's meters, and meeting marks. Words in candle at 12 pt or less use the darker text step (`candleText`). |
| case | `#EDECE9` | `#1E1F21` | Settings window background (Settings, History and Meetings pages) |
| plate | `#FBFAF8` | `#2A2B2E` | A grouped section, with a 0.5 pt hairline |
| bubble | `#181A1C` at 92% | same | The overlay, over a blur |
| lights | green `#2FB765`, amber `#F2A417`, red `#E2372D`, off is a hollow ring | same | Status lights |
| voices | lavender `#6A4FC4`, sky `#1F6AA5`, rose `#B03A72`, teal `#0E7470` | `#B4A5F2`, `#7CC4F2`, `#F29BC0`, `#5FD0C8` | Other people in one meeting, in the order they first spoke (`VoiceColors`): their dot in the cast line, their lane in the player strip and their name in the transcript and over their Sidekick bubbles. You are moss. A voice with no name keeps its colour too, and naming it doesn't change it; it's told apart by a dashed ring and a dashed underline, never by candle. |
| your bubble | moss `#2B7D4F` at 16% | `#34965F` at 36% | Your own lines in a transcript, under ordinary text; everyone else's bubble is 7% of the text colour |

### Type

- SF Pro for everything, in eight sizes. They live in `GoblinBrand.swift` as `Font` tokens; a page never invents a size.

  | Token | Size | Job |
  |---|---|---|
  | `.capsLabel` | 10 pt semibold, tracked | The small-caps label above a plate |
  | `.meta` | 11 pt | A second line, a footnote, a count |
  | `.status` | 12 pt | A status sentence, text in a small control |
  | `.row` | 13 pt | Body text, row titles, buttons (semibold for a title) |
  | `.transcript` | 14 pt | What people said, in a Sidekick bubble, and a finished meeting's notes |
  | `.cardTitle` | 15 pt semibold | The title of a card, a sheet or a toolbar |
  | `.reading` | 17 pt | Text read at length: a dictation, the first-run prompt |
  | `.hero` | 28 pt bold | First-run headlines and a meeting's title |

  Three exceptions: the overlay's live words (`.overlayWords`) and the Sidekick's notes are 15 pt, and the Insights headline numbers are 48 pt.
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

Use them for the popover header status, the Settings sidebar footer and counts, the last row of a settings group, and the first-run steps and setup cards. In a setup card only (first run and the Meetings setup sheet), a 9 pt small-caps label (ON, WAIT, OFF) sits under the dot.

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
| cackle | `goblin-cackle.png` | The first take and new treasures only |
| eyes | `goblin-eyes-ahead.png`, `goblin-eyes-<n…nw>.png` | Popover header, About and the Hoard: slit pupils looking ahead or toward the pointer |
| grip hands | `hand-grip.png` | Gripping the top edge of a card or field. Mirror it for the right hand. |
| open palm | `hand-palm.png` | "Not touching that": no microphone, password field |
| quill fist | `hand-quill.png` | Transcribing |
| props | `prop-zz`, `prop-drop`, `prop-candle`, `prop-spark`, `prop-coin` | Asleep, sweat, candlelight, celebration |

The first two frames already ship in `Sources/GoblinApp/Assets/`. The rest are in `docs/design/sprites/`. Copy one into Assets when a surface needs it, and run `xcodegen generate` afterwards. The old 7 × 7 fists in `hands.png` are retired once the grip hands land.

The menu-bar icon (`GoblinBrand.menuImage`) is the 22 px goblin in `design/menu-icon/draw.py`, doubled pixel for pixel for Retina. While a meeting records, the goblin wears a pixel headset from the same script (`menu-headset*.png`), graphite on a light bar and pale grey on a dark one. It's a shape, not a colour, so it never reads as a status light, and it stacks with the state dot: dictating during a call shows both. Settings can add the elapsed time beside it. On a light menu bar its edge and the state-dot ring are black. On a dark menu bar the edge and the ring are dropped, and each green is drawn one step lighter, so the bar itself outlines the goblin and the shading doesn't sink into it. Any outline on a dark bar reads as a glow. To change it, edit the map and rerun the script; don't edit the PNGs by hand.

The Hoard's treasures come from `design/hoard/draw.js`, one 24 × 26 pixel PNG each in `Sources/GoblinApp/Assets/hoard/`, named by the treasure's id in `Sources/GoblinCore/Hoard.swift`. The object stands in the top 20 rows on a plinth whose material climbs its shelf: wood, tin, copper, silver, gold, emerald, goblinite. Secrets stand on amethyst. Fills come from the goblin's own palette and every shape gets a one-pixel ink ring; flames, sparks and runes are glow and go unringed. Show them at 3× on a shelf, 2× in the overlay and beside a meter, and 8× up close. Purple and green can appear anywhere, a potion or a gem early on, but they gather on the top rungs and the secrets, so the hoard turns more goblin as it fills. To change one, edit its drawing and rerun the script.

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
- The whole visible shape of a control is its click target. Plain-styled buttons, menus and rows get a `contentShape` that covers their padding, and a popover row with one menu opens it from anywhere on the row, and in a row with two controls each reaches its own end of the row.

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
| cleaning up | squint | Words with a highlight sweep every 900 ms. Subline: "Cleaning up · Light · Cerebras", led by the profile when it isn't Everywhere ("Code · Light · Cerebras", "Posts · Custom · Cerebras"). Only shown when Cleanup is on. |
| inserted (new) | closed, one nod | A one-line chip: "Typed into Mail · 23 words · 0.59 s", with the profile before the count when it isn't Everywhere ("Code · 23 words"). It leaves after 500 ms. |
| cleanup failed | sheepish | "Cleanup took too long, so I typed your words as you said them." Subline: `Cleanup › Cerebras didn't answer within 4.0 s`. Stays 2.5 s; hovering holds it. |
| no microphone | squint, palm | "I can't hear anything. No microphone is connected." The subline holds "Choose Microphone…". Stays until dismissed, or 6 s. |
| microphone silent | same while listening | A line under the header names the cause: muted, volume at zero, or no sound arriving. Device reports warn despite nonzero noise and clear on hardware recovery; a generic silence notice may remain. Sample-only warnings use 5 s before any sound or 15 s after sound and clear when sound returns. Recording continues. |
| new microphone (new) | side-eye | Asks once, when a microphone is seen for the first time: "Lav Receiver just connected. Should I use it for dictation?" Subline: `Audio › new microphone` with Not Now and a moss Use It. If a take is running, or starts while it's showing, it comes back when the take ends. It isn't asked when macOS already switched to the mic and gob.lin is following macOS, since the mic is already in use. Stays 12 s; hovering holds it. Ignoring it leaves the mic under "Only when picked". |
| different microphone | same while listening | When a take uses a different mic from the last one, a quiet line under the header names it: "Using Lav Receiver". If the mic drops out mid-take, the take moves to the next mic in the ranking and the line says so: "Lav Receiver dropped out · now MacBook Pro Microphone". A silence notice replaces it. |
| password field | side-eye, palm | "That's a password field, so I didn't type there." Subline: `Insert › Secure Input is on`. |
| word offer (new) | look down | After a fix the goblin learned from: "Add “panacea” to the dictionary?" Subline: "You fixed “anasia” · gob.lin" ("You fixed it 5 times · everywhere" after repeated fixes), Not Now and a moss Add. Like the microphone question, it waits for a running take and comes back after one that interrupts it. Stays 8 s; hovering holds it. Overlay settings can turn it off. |
| profile question (new) | side-eye | After a take lands in an app with no profile, while sorting is on. Unsure guess: "I used **Code** for **Linear**. Keep it there?" Subline: `Cleanup › my guess` with Not Now, a Change menu of the other profiles and a moss Keep. No guess: "Which profile should I use for **Figma**?" from the second such take, with Not Now and a moss Choose menu. Asked once a launch per app, only about the app the text landed in. Waits for a running take like the other questions. Stays 8 s; hovering holds it. Overlay settings can turn it off. |
| word added (new) | closed | A one-line chip: "Added panacea for gob.lin". It leaves after 1.5 s. |
| meeting question (new) | side-eye | A call app has held the mic for 2 s and its app is set to Ask: "Zoom is using your mic. Should I record this call?" Subline: `Meetings › Weekly sync` with Not Now and a moss Record. With System Audio Recording off it says "Zoom is using your mic, but I can't hear the other side yet." with the subline `Meetings › no call audio`, and offers Open Settings instead. It waits for a running take like the microphone question. Stays 12 s; hovering holds it. Ignoring it or Not Now leaves a Record row in the popover while the call lasts. While the screen is locked a notification asks instead; clicking it asks again here, and only its Record button records. |
| meeting recording (new) | closed | Only when the Sidekick is off: a one-line chip, "Recording Weekly sync · Let people know you're recording." It leaves after 2.5 s. |
| meeting ready (new) | closed | After processing: "Weekly sync is ready · 42 min · 1 voice to name" with Open. Stays 4 s; hovering holds it. |
| meeting stopped (new) | side-eye | Sleep or the lid cut a recording short. Said on wake, once the screen is unlocked: "Recording stopped because the Mac went to sleep, so I kept the first 31 minutes." Subline: `Meetings › slept at 10:31` with Dismiss, and a moss Record the Rest while the call app still has the mic (it records part two). If the call ended meanwhile, a notification says it instead. |
| quiet room (new) | closed, Zz | An in-person recording has heard nothing for 10 minutes: "It's been quiet for 10 minutes. Stop recording?" Subline: `Meetings › Conversation` with Keep Going and a moss Stop. Stays 20 s; ignoring it keeps recording and asks again after another quiet 10 minutes. |
| treasure (new) | cackle, sparkles | Something new is in the Hoard. A dictation that lands replaces its inserted chip with a treasure at most once a day: the most precious find of the last three days, even one from earlier, such as a meeting. It shows the treasure at 2×, its name ("Doorstop.", "A secret: Cackle."), the goblin's line and "It's in the Hoard." in candle. The rest wait in the Hoard. Nothing shows while a meeting records. The bubble edge glows candle. Stays 2.5 s. Overlay settings can turn it off. |

Any other error uses the same form: a symbol, one first-person sentence, and an `Area › cause` subline.

Motion: in is opacity 0→1 and y +8→0 over 140 ms with ease-out; out is 120 ms. New words fade in over 80 ms.

### Menu-bar popover

`GoblinApp.swift`. Use `MenuBarExtra` in window style: a 360 pt glass panel. What's happening comes first, then what you said, what you recorded, and the settings last. Top to bottom:

1. **Header:** the goblin at 64 pt, whose eyes follow the pointer anywhere over the popover and look ahead when it leaves (side-eye while something needs attention), the wordmark, a status light with a sentence ("Ready · hold fn to talk"), and a ⋯ button. While the goblin has dictionary suggestions, one moss line under the status ("3 new words for gob.lin") opens the Dictionary page.
2. **Meeting:** only while Meetings is on and there's something to say. After a meeting is processed and until it's opened or dismissed (×), a ready card: the moss check, "Weekly sync is ready", "42 min · Zoom · I knew Sam's voice", an amber "1 voice still needs a name." when one does, then Who's This? (moss, opening the meeting with Who's this? on its first unnamed voice) and Open, or a moss Open when every voice has a name, and Copy Transcript. It outlasts the overlay's ready chip and a relaunch. While recording: a moss headset circle (two people, in person), the title and "Recording Zoom", the elapsed time at 15 pt and Stop (hidden while the countdown's Stop Now shows, so there's one Stop); You and Them level bars in moss on a faint baseline that's flat while quiet (one Room row in person); then the line that matters now: the auto-stop countdown ("Zoom let go of the mic, so I'll stop in 0:47.") with Keep Recording and Stop Now, the quiet-room question with Keep Going, a lost mic or lost call sound, a silent mic, the mute line ("You're muted in Zoom, so I'm leaving your mic out."), the speech model's first download, or captions left for after the call. Under it Mark This, Show or Hide Sidekick, and the number of marks. After Stop: "Sorting out who said what…" with a small spinner. With a call on the mic that isn't recording: "Zoom is using your mic · Weekly sync · not recording" with a moss Record. With System Audio Recording off: an amber module, "I can only hear your side of calls until you turn it back on.", with Open System Settings.
3. **Problems:** only while true. Each is an amber module with a plain title and sentence (`DiagnosticFailure.plainWords`) and the one button that fixes it (`AppModel.fix(for:)`).
4. **Update:** only when an update is available, with a Restart button.
5. **Dictations:** a small-caps label with "Paste Last Dictation ⌥⇧⌘V" at its end, in moss, or grey while there's nothing to paste, a search field and the four latest dictations. Hovering a row shows copy and star. Then "All History".
6. **Meetings:** while Meetings is on. A small-caps label with a Record Conversation capsule at its end (people talking in the room, from the mic alone), hidden while a meeting records and disabled while one is starting or stopping, then the last week's meetings, three rows drawn like the dictation rows (the call app's icon, the title, "Zoom · 42 min · 1 hour ago", and an amber light with "2 voices to name" or "Processing"), as many as fit under the menu bar up to three (the popover doesn't scroll, so on a short screen with the ready card up it can be All Meetings alone), then All Meetings ›. A row opens its meeting. While the ready card is hidden (a recording or processing holds the module), its meeting is listed here. Before the first meeting, "Your meetings show up here." stands in for the rows and All Meetings.
7. **Settings:** one module of three rows, each a 24 pt circle, the name, and what it's set to with a chevron, opening a menu.
   - Microphone: the microphone in use, a picker in ranked order ending with Edit Ranking…, and press-and-hold "Hold to Test". The mic opens only while it's held, and the level takes the place of its name, unless the mic is silent and there's no level to show; nothing is recorded or saved. The picker and Hold to Test are separate targets. A line under the row appears only while there's something to say: which mic is standing in while a higher-ranked one is away or the lid has silenced it (during a test it names the mic being tested), a silent mic, or an error.
   - Cleanup: clicking the circle toggles it; the rest of the row opens the level menu for the profile of the app last in front, and "Light · Cerebras" names that level.
   - Profile: the whole row opens a menu: which profile the app last in front uses, that profile's tone, and Profile Settings…. The row reads "Code · Casual".
8. **Footer:** "Insights" with this week's words and the last seven days as bars, and "Settings… ⌘,".

The ⋯ menu is a plain menu: Permissions… (with the number that are off), Diagnostics…, Copy Diagnostics, Check for Updates…, About gob.lin, and Quit gob.lin ⌘Q.

Right-clicking or Control-clicking the menu-bar icon opens a native menu instead of the popover: Cancel Dictation ⎋ (only while recording), then while Meetings is on either Mark This (⌃⌥M) and Stop Recording, or Record Zoom Call (when a call is on the mic) and Record Conversation, then in both cases Recent Meetings (a submenu of the five newest, each with when and how many voices need names under it and an amber dot when any do, then Copy Transcript of the newest finished one) and Open Meetings, then Paste Last Dictation ⌥⇧⌘V, Settings… ⌘,, then the ⋯ menu. Both menus come from the same lists in `Menu/StatusMenu.swift`.

### Sidekick

`Sources/GoblinApp/Meetings/Sidekick*.swift`. Live captions while a meeting records, on by default (Settings › Meeting Recording › Show Sidekick). It is the overlay's dark glass and the overlay's whimsy budget.

- **Window:** a real window, always dark, with the traffic lights on a transparent titlebar and no title. A click brings it forward like any window, and it keeps the keyboard until you click elsewhere. It drags from anywhere that isn't a control and resizes from every edge. It first opens at the top right, 16 pt in, clear of the overlay's corner (below a top overlay, above a bottom one), then remembers a compact and an expanded frame, and stays on screen when displays change. It shows in Mission Control, joins every Space and floats over full-screen calls, but stays out of ⌘-Tab. Keep on Top (the pin, and the ⋯ menu) floats it over other windows, on by default; off, it's an ordinary window. Red hides it until the call ends, like Hide; yellow collapses it to the pill.
- **Panel:** compact, 320 × 480 pt at first and at least 300 × 360; the captions grow with the window. The system draws its corners, edge and shadow.
  - Titlebar strip, 32 pt: the traffic lights, then on the right Notes, Keep on Top (a pin, filled while on) and a ⋯ menu (Copy New Lines, Copy All, Show or Hide Notes, Keep on Top ✓, Collapse to Pill, Hide Until the Call Ends, Stop Recording).
  - Header: the goblin at 64 pt, 12 pt in, looking toward the middle of the screen from wherever the window is; a neon reel (a ring with a dot), "Recording" and the elapsed time (12 pt, 62% and 55% white); "Zoom · Weekly sync" (11 pt, 55%).
  - Levels: five-bar neon meters for You and Them, or one for the Room in person. A muted or dictating side goes idle. On the right, the mic being recorded, its name and a chevron (an amber mic-slash while it's silent), opens a menu: Same as Zoom (Same as Dictation in person), checked by default with the mic it's using under it, then every mic, the built-in one disabled while the lid silences it. The choice is remembered for later meetings. Same as Zoom follows the call app's mic when it switches. A picked mic is used whenever it's connected, the built-in input only while the lid is open, or while it's using a wired headset's mic; meanwhile the call's mic stands in (dictation's ranking in person). While it's away it stays checked, greyed, with "Not connected" (or "More than one is connected. Pick one." when two identical mics are plugged in and it can't tell which). A muted or zero-volume pick stays in use and shows the silence warning.
  - Captions: laid out like Messages, with `TranscriptBubble`. Your lines are on the right in your bubble; everyone else's are on the left in grey, with their name above in their voice colour when the speaker changes ("Them" until names come live). On a call, one side's lines flow into one bubble (a new one after a minute). In person there's no name, since voices are sorted out after Stop, and a new bubble starts after a line that ends a sentence. With names live, a line whose voice isn't placed yet says "Them" in grey over a quieter, dashed bubble; once the speaker model places it, it takes its voice's label, "Speaker N" or a name. The time shows only once it has moved a minute. Words at 14 pt in 94% white. The time, and the words of a line not placed yet, are the secondary label colour, about 53% on the glass (5:1 over a white desktop); the system lines are 55% white and the consent line 60%. The first lines say "Let people know you're recording." (dismissable) and "Names come after the call. Live, I only know you and them.", or once the live speaker model is running on a call, "I'm guessing names from voices I know. I'll check them after the call." Live, the call's voices are told apart about 3 s behind the audio, and each is "Speaker N" in the order the voices came in. With Remember voices on, a voice is first matched against People once it has said about 4 s with nobody talking over it, then at 10 and 20 s, among the call's participants when the call app lists them; it takes the name only on a confident match, so it can stay "Speaker N" all call. A name given later renames that voice's earlier lines. With Remember voices on, the mic's voices are told apart the same way: every mic line arrives as yours, and one whose voice turns out to be someone beside you moves to the left under "Speaker N" or their name, numbered with the call's voices in the order each was told apart; the after-call pass numbers them by who spoke first. A call taken alone never shows anyone on the mic but you. The after-call pass decides the names that are kept. It follows live; scrolling back shows a Back to Live capsule on the panel's glass. A 14 pt top fade. A thin scroller floats over the right gutter while the captions scroll or the pointer is over them, then fades; it takes no width. While the call app shows you muted, your mic's lines stay out of the captions and Copy, as they do from the transcript.
  - Marks: a candle-tinted row with a flag, the time, and the label or "Marked" with Add Label.
  - Footer: one status line (what's recorded; the mute line in amber; a lost mic or lost call sound in amber, "I lost your mic, so I'm only recording Zoom. I'll pick it up again when it's back."; a silent mic in amber, "Lav Receiver is sending only silence, so I can't hear you." (or muted, or at zero volume) with Choose Microphone…; the speech model's first download with its progress; "I fell behind on captions, so I'll transcribe some of this after the call."; the auto-stop countdown with Keep Recording; System Audio Recording off with Open System Settings; the quiet-room question with Keep Going), then Mark This ⌃⌥M and Stop as 28 pt capsules, Stop tinted red so it never passes for Mark This.
- **Expanded:** Notes widens the same window to its remembered expanded frame (860 × 600 pt at first, at least 640 × 420, growing toward the middle of the screen): your notes on the left, everything above in a 340 pt column on the right. The notes column: "YOUR NOTES" in caps, then a plain editor at 15 pt on the glass with no scroller beside it, "Jot anything down. I'll fold it into the notes after the call." while empty, and "I'll fold these into the notes after the call." (12 pt, 55%) under the text once there is some.
- **Pill:** its own small floating panel that drags from anywhere, placed where the window's top right was. A 196 × 40 pt capsule with the reel, the time, one meter, a candle flag (Mark This) and Expand, which brings the window back at its frame, with the goblin at 64 pt beside it, bottoms aligned, on the side nearer the screen's edge, like the overlay. Dropped on the other half of the screen, the goblin moves to the other side and the capsule stays put. The goblin is never inside the capsule.
- **Faces:** eyes toward the middle of the screen; look down with the quill for 1.5 s after a mark; closed while the room has been quiet.
- **Motion:** fades in over 160 ms and out over 120 ms; showing or hiding the notes resizes the window over 200 ms, and at once under Reduce Motion.

### Settings

`Sources/GoblinApp/Settings/` and the per-page views.

- **Case and plates:** the window background is the case, and each group is a plate with a 10 pt small-caps label above it.
- **Window chrome:** the sidebar is always visible (no toggle), with the traffic lights inside it. The page title is the window's toolbar title, level with the traffic lights, and the toolbar draws no band, so the case runs to the top of the window. Scroll views use the hard top edge effect, so scrolled content stops at the toolbar and never shows through the title.
- **Status rows:** a group may end with one status row: a light, a sentence, and either a right-aligned detail or one button.
- **Sidebar:** the pages you read, Insights, Hoard, History, Meetings and People, then a rule, then the settings: General, Audio, Model, Dictionary, Cleanup, Meeting Recording, Overlay, Diagnostics, About, all with SF Symbols. Meetings, People and Meeting Recording show only while Meetings is on. A row may end with an amber light and a count when items there need you (Meetings: meetings with a voice to name). The Hoard's row ends with a candle dot and a count of treasures found since it was last open: new, not a problem, so never a status light. The footer is a status light, "Ready", and the engine and where it runs ("Parakeet v3 · on this Mac").
- **General:**
  - Talk key: a big keycap card with the key, one sentence on how it works, and Record New Key…. Quick picks: fn / Globe, Right ⌥, ⌥ Space. Cancel a take: esc, or the overlay's × when esc is the talk key. A status row for the Globe key setting.
  - Behaviour: Open at login, Click sounds, Add a space after each take.
  - iCloud: Sync Dictionary and Sync History switches, off by default, each with a line under it saying what syncs and the rest behind its ⓘ. Each shows only in builds signed for it, and the group only when one does. A red status row appears while the last dictionary sync failed. Sync History ends with one status row: green while syncing; amber with the one button that fixes it while waiting for iCloud, while iCloud is full, or while dictations from a newer gob.lin are left out; hollow when sync turned itself off because gob.lin's iCloud data was deleted or a different account signed in.
  - Reduce audio while dictating: independent Pause current media and Mute audio switches. Explain that pause preserves the current player's position, mute lets playback advance, and both can be enabled. Preserve the existing pause preference; mute starts off.
  - Typing it in: the paste-last shortcut with Change…, a status row for the insertion mode and the last insert, and a status row for permissions with Open Setup….
  - Meetings: the Record meetings switch. Turning it on the first time opens the Meetings setup sheet; while it's on, a status row leads to Meeting Recording….
- **Audio:** Microphones is the ranked list. Each row has a light (green in use, amber silenced by the lid, hollow otherwise), the name, and its transport and state, plus a menu with the same moves as dragging. The System Default row is the line: mics above it are used in order, mics below it ("Only when picked") never on their own. A status row names the mic in use and the one it's standing in for.
- **Cleanup:** the switch, sorting and everything in a profile apply as soon as they change; the provider is edited in a sheet and applies on Save. A profile is how gob.lin writes in one kind of place: its tone, level, formatting and prompt. Each app uses one; Everywhere covers the rest, comes first and can't be renamed or deleted. A new install starts with Code, Chat and Email & Docs, holding the apps it has from each one's suggestions; an update starts them empty, with Everywhere holding the level, formatting and tone set before.
  - A top plate with the AI cleanup switch and a status row naming where the text goes. Turning it on with an unfinished provider opens the provider sheet, whose button reads Save and Turn On.
  - Provider: one row naming the service, with the model, host (Local and Custom), speed (OpenAI, when not Standard) and "key saved" under it, and Edit…. While the provider can't run, an amber row says what's missing, with Set Up….
  - Provider also holds, for cloud providers, a “Send text near the cursor” switch, off by default, whose line says what is sent and to whom, with the rest behind its ⓘ; the top status row then says the text near the cursor goes too.
  - Sorting: Sort new apps (a decision model picks a new app's profile from its name: sure picks stay, unsure ones are used once and asked about in the overlay, and apps it can't place use Everywhere), Sort browser tabs under it, indented and disabled while it's off (the window title decides, take by take), Decides with (Automatic, OpenAI, OpenRouter, TypeSafe Jev, Apple Intelligence; Automatic names its pick), a Model menu when sorting goes through OpenRouter (Perplexity Decider 1.2 by default, Decider latest, TypeSafe Jev, Liquid D1.2, Cloudflare Clef Flash, Inception Mercury Decide), a TypeSafe API key field when Jev is chosen directly, and a status row while sorting is on.
  - Profiles: a plateless list in one plate, each row an SF Symbol, the name, the "When to use" line, and "Light · Casual · 3 apps" on the right; the selected one is a moss tint. New Profile sits under a hairline. Everything below edits the selected profile, starting under a header with its name.
  - Details: Name and When to use fields (sorting reads When to use), and Delete Profile…, which asks first. Everywhere's has its one line instead.
  - Apps: one row per app with its icon, "Sorted by me" for apps gob.lin placed, and a ⋯ menu with Move to and Remove, then Add App (Suggested, Open apps, Choose Another App…). An app is in one profile at a time.
  - Tone: Formal, Casual and Very casual as rows, each with the sample sentence in that tone under it and a moss check on the chosen one. It works without AI cleanup.
  - Level: None, Light and Medium as rows drawn like Tone, each with its description and the same sentence as an inline diff of what that level types. They're disabled, with a hollow status row saying why, while the profile has its own prompt. The ⓘ lists what every level writes as typed (web addresses, versions, slashes).
  - Formatting: Paragraphs, Lists, Say “New Line” and Commands and Issue IDs switches, each with one line under it and its examples behind the ⓘ. They're disabled while the level is None or the profile has its own prompt.
  - Prompt: My prompt with Copy and Edit Prompt, and Show Prompt disclosing the text in SF Mono. Edit Prompt copies it into an editor in the plate for that profile, with Apply the tone after cleanup (off), Copy and Reset to Default; a waiting row when it's empty, or too long for Apple Intelligence. The transcript and spellings always go as delimited data, and empty or late cleanup is never typed, whatever the prompt says.
  - Try it: the sample text as an **inline diff**, one sentence, or with any formatting on a few that make a list and a new paragraph, laid out as typed, or a command and an issue ID when only Commands and Issue IDs is on. It runs the selected profile. A removed line break shows as a struck "↵". Cut words are struck through on a red tint and added words sit on a green tint, with Run Again. The group's ⓘ holds the timeout note: "Slower than 4 s? I type what you said instead."
  - The provider sheet: Service, Address (Local and Custom only; named services use their own), Model (a free field with a chevron menu of suggested models, then the ones the service lists for the key), Reasoning, Speed (OpenAI only: Standard, Fast, Ultrafast), API key (masked, "Saved in gob.lin preferences", Remove), the model-list status row with Refresh, and Advanced request options. Every control ends on the same right edge. Cancel and Save.
- **Dictionary:** while there are suggestions, a card above Terms with the look-down goblin at 64 pt gripping its top edge. A title in the goblin's voice ("I found some words in gob.lin"), the budget ("22 of 32 words for gob.lin"), and one row per word with a reason caption ("you fixed “go blin”", "from Package.swift", "you fixed it 6 times · sounds like “soul”, “sole” near GPT, 6.1"), Not Now and Add, plus Add All. Nothing is added without a click. A word learned from a fix is also offered once in the overlay; Not Now there is the same as Not Now here. Below it, one plate. Its header is a search field, a ⋯ menu holding Import Words… and a moss Add Term. Under the header the plate splits in two and hugs its content: places on the left, drawn with `SidebarRow` (Everywhere, apps with their icons and a chevron that opens their projects, then Other Projects), and the selected place's words on the right, as a table with Word and Sounds Like columns in SF Pro; Sounds Like ends with the context words ("soul, sole · near GPT, 6.1"). Its header has the place, the app icon and a meter ("32 of 32 active") that opens the words in priority order. The selected place is a moss tint. Edit and delete appear on hover, and in the row's context menu.
- **Meeting Recording:** only while Meetings is on.
  - The same Record meetings switch, then a status row: off ("Off. Nothing loads until you turn it on."), System Audio Recording off (amber, "so I can only hear your side", Open System Settings), notifications off (amber, Open Notifications), recording, processing, or "Ready. I'll ask when a call starts." with the last meeting on the right.
  - When a call starts: one row per call app with its icon and an Ask / Always / Never popup, a single row for meetings in a browser, then Show Sidekick. The group's ⓘ explains the three choices.
  - In the room: Record a conversation, with a Record Conversation button, saying it uses only the mic and is in the menu bar too.
  - Speakers: the Remember voices switch, on when the setup sheet's Remember voices was left on, with "Keeps voiceprints on this Mac so I can name people next time." under it. While it's on, a status row says who I know ("I know 4 people by voice.", amber while I learn from the meetings already recorded) with People…. Turning it off asks first: "Forget every voice?" with Turn Off and Forget.
  - Notes: Notes model (Best Available, each signed-in tool's models grouped under Codex and Claude Code, None), whose line says which model that is and where transcripts go; Thinking (Default and the model's levels), only when the model has levels; Template with Edit… (the template sheet: your templates on the left, a name, a line on what it's for, and the instructions; New From starts one blank or from a built-in); Style (Concise / Detailed, segmented); Write notes after each call. A status row says which tools are signed in, with Check Again; amber with Copy Command when one needs `codex login` or `claude auth login`.
  - AI apps: one row each for Claude Code (a terminal tile), Codex and ChatGPT (whose ⓘ says the three share one setting) and Claude, with the app's icon and a line saying whether it's connected or where what it reads goes ("Not connected. Once it is, what it reads goes to OpenAI."). A connected row has Disconnect; not connected, Connect, disabled when the app isn't installed; one set up for another copy of gob.lin, or turned off in Codex, has both. While a change runs, the row's buttons give way to a small spinner. After Claude is connected while it's open, its row says to quit and reopen it so the connection loads; after it's disconnected while open, to quit it to end any session it may still have. A status row says who can read meetings ("Claude Code can read your meetings, never change them."), "Looking for AI apps…" until it knows, and red when connecting or disconnecting failed, with Copy Command for any other app. The group's ⓘ footer says what an app can read, that it chooses when, and where it goes.
  - The Export folder is present but disabled with "Coming later", so the page keeps its shape when it lands.
  - Storage: Keep audio, 1 week (starred meetings keep theirs), and a status row with the meetings' audio size and Show in Finder.
- **People:** only while Meetings is on. Plates on the case like a settings page.
  - Voices: one status row. Hollow with Turn On while Remember voices is off ("Remember voices is off, so I don't keep anyone's voice."), amber while learning, green with who I know. What a voiceprint is waits behind the ⓘ.
  - You, then People: one row per person with their initials, name and "3 meetings · 4 min heard · last heard 17 Nov", opening (`RowDisclosureStyle`) to one row per meeting their voice came from: a moss play circle (grey once that meeting's audio is gone), the meeting's title and when, which opens the meeting, and a trash button on hover. A ⋯ menu holds Rename…, Merge Into and Forget…, which asks first.
- **About:** centred.
  - The goblin at 128 pt, whose eyes follow the pointer anywhere over the page, the 48 pt wordmark, the version, and the tagline with a blinking block cursor.
  - Two plates, one above the other: four sentences of lore with three stats (words yapped, dictations, 0 s of audio uploaded), then spec rows (recognition, runs on, model size, languages, network).
  - Check for Updates…, Licences, Data Folder.

### History

`Sources/GoblinApp/History/`. History is a page in the Settings window (about 1100 × 720), opened from "All History" in the popover. It draws its own toolbar title and buttons over a list beside a detail; the window's sidebar stays.

- **Filter:** a menu at the top of the list: All Dictations, Starred and Warnings, each with a count, then Apps with counts. The filters run in the store query, not on the loaded page. The list's footer holds retention with Change….
- **List:** grouped by day. The selected row is a moss tint. A row is the app icon, app name, time, a two-line preview, the length, a star, and "Not inserted" when it failed.
- **Detail:**
  - The app and title, then the time and length.
  - The text at 17 pt, then playback with a waveform.
  - A fact strip: Words, Profile (when it was written with one), Tone, Cleanup, Speech model.
  - "537 ms from key-up to text in Mail", above a stacked bar split into Transcribe, Cleanup and Paste.
  - "What you said": the raw transcript, with the words cleanup cut struck through (the same inline diff as the Cleanup page).
  - Re-transcribe and Rewrite under the text. Rewrite uses the dictation's profile; its menu rewrites as any other. Star, copy and delete sit in the toolbar.
- **Insights:** plates on the case, numbers in monospaced digits, chart bars in moss. A Today / This Week / All Time selector in the toolbar sets the period for the whole page. Only Streak ignores it, because a streak always counts back from today.
  - Summary, headed by the period: Typing saved and Words as two big numbers, the talking time in the goblin's voice ("You talked for 59 minutes. I did all the typing."), and the look-down goblin at 128 pt with its quill, sitting on the plate's divider. Below it: Dictations, Speaking pace and Streak. Typing saved is the time to type the words at 40 words a minute, less the time spent talking.
  - Activity: bars stand on faint full-height tracks, labelled on the current bar and the peak, which is the full-moss bar and bold label when it's the current one. The hour grid is 7 × 24 square cells in four steps of moss. Hovering a bar or a square shows its count. Today is words per hour across the whole plate. This Week is words per day with a dashed average beside When you talk, and ‹ › step a week at a time. All Time is the last 12 months with a dashed average beside When you talk by weekday.
  - What you talked about: the pixel word cloud for the selected period. The side-eye goblin grips the top edge of the biggest word, and smaller goblins and sparks appear only where a gap fits them. The layout is seeded by the day and period, so it doesn't reshuffle on every visit. Hovering a word shows how often you said it.
  - Where you talked, only when the period has dictations from more than one device: the device's symbol, name, words, dictations and share. Where I typed: app icon, name, words and share over a thin moss track; an iPhone can't name the app it typed into, so its dictations make one row named after it, with its symbol. Counts and shares use the selected period's words. Then "How I count".
- **Hoard:** `Sources/GoblinApp/Hoard/`. Treasures found by using gob.lin, on the case in plates like Insights. Unlike the settings forms it isn't capped in width: the plates fill the window, so a wider window fits more on each shelf.
  - Summary: the goblin at 128 pt with its eyes following the pointer, as on About, the count in 48 pt ("39 of 107 treasures"), one sentence on the closest treasure ("My hoard grows. Skeleton Key is 4 apps away."), a candle meter of the whole hoard and the latest find. Under a hairline, the three treasures closest to found, as silhouettes with candle meters. Streak and biggest day are personal bests, not running totals, so they aren't among them, and up close they say "Best so far". Finds show from the Hoard's own record at once; the shelves History fills show progress only once History has been read. When it can't be, a red status row says progress may be behind.
  - One plate per shelf, headed by its name and "7 OF 12": each find at 3× on its own plinth, with no glow or ledge under it, its name and the day it was found (or what it took, for finds from before the Hoard). The next rung is a silhouette with what it takes and a meter; the rest wait unseen, counted by the header. Secrets all show, unfound ones as "???" silhouettes. Finds new since the last visit say NEW in candle after their date. Meeting shelves show while Meetings is on, or once they hold something.
  - Clicking a treasure opens it up close: the sprite at 8×, its name, what it takes, the goblin's line, when it was found or how far there, and its plinth.
  - Nothing is taken back: deleting History or a meeting never removes a treasure. Dictations count from every device, the iPhone too.
- **Empty:** the closed goblin at 128 pt with Zz, then "Nothing to snitch on yet." and "Hold fn and say something. I'll keep the receipts."
- **Problems:** save errors and unsaved dictations are amber status plates with one action each.

### Meetings

`Sources/GoblinApp/Meetings/`. A page in the Settings window under History, built like History: a 330 pt list beside the meeting. It appears once Meetings is on. Meetings are calls, recorded from the call app and the mic, or conversations in the room, recorded from the mic alone.

- **Toolbar:** "Meetings" with the count and total length under it, Show or Hide Transcript (⌥⌘T, remembered like an inspector), a Copy menu (Copy Notes, Copy Transcript, Copy All as Markdown: the notes, what was typed and the transcript as one note), a Delete menu (Delete Notes…, Delete Audio Only…, Delete Meeting…), and Search meetings.
- **List:** a filter menu (All Meetings, Needs Names, then sources), then meetings grouped by day. A row is the call app's icon (a two-people glyph for a conversation in the room), the title, the start time, who spoke, then the length, the source ("Zoom", "In person") and its states: an amber light with "1 voice to name", Processing or Recording, a red one with Couldn't finish, and plain "· Stopped early" and "· No audio". The selected row is a moss tint. The footer is the audio kept and its size, with Change… to Meeting Recording.
- **Detail:** one document on the plate, at most 760 pt wide and centred, with no boxes inside it except Needs You. A bar runs under it, and the transcript opens beside it.
  - The title at `.hero`, editable in place (clearing it removes the typed title, and the order under "The title" below picks again; leaving it unchanged saves nothing), then "Monday 16 November at 14:00 · 42 min · Zoom".
  - The cast line: one name per voice with a 9 pt dot of its colour and its talk time. A voice with no name has a dashed ring and a moss "Who's This?" and opens Who's This?. A voice I named because it sounded like someone in People has an open ring and "guessed", and its menu leads with Yes, That's Sam and No, Rename…. Any other voice's menu has Rename…, Merge Into and Play Their Voice. The participants nobody heard follow in one grey line.
  - After a change (a name, a merge, a rewrite, a correction, a word put back), a moss-tinted line says what changed, with Undo, which is also Edit › Undo. A merge while someone on the call has no voice yet says "Sam Okafor doesn't have a voice yet." with Name Speaker 3 Sam Okafor Instead. A rewrite from an ask offers Save as Template….
  - Status lines for processing (with a spinner), a failure (Try Again), and "Recording stopped at 31:12 because the Mac went to sleep."
  - Needs You: an amber-tinted card, only while something waits on the person, in ordinary text. Voices first, "I need a name for Speaker 3. They talked for 8 min." (or "I need names for 2 voices.") with a moss Who's This?, then the words that may be misheard names. One word reads "“Okafur” may be a misheard name: Okafor." with Keep As Heard and a moss Fix, and under it the line it was heard in, cut to the words around it with the heard word in semibold, and a play button. More read "2 words may be misheard names: “Okafur” → Okafor, “Pria” → Priya." with Review… and a moss Fix All; Review… lists each word in context and turns into Done. Its buttons go under the sentence when the page is narrow. After Fix or Fix All, a moss line offers "Add Okafor to the Dictionary, so dictation and later meetings spell it right?" with Not Now and a moss Add; nothing is added without the click.
  - The notes, as a document at `.transcript` size: the summary, ACTION ITEMS as checkboxes you can tick (the owner in semibold, the due words quieter; a ticked one is struck through and kept), DECISIONS with a moss check or a candle question mark and "Still open" or "No agreement" in candle, the template's sections under `.cardTitle` headings, YOUR MARKS as candle flags, and YOUR NOTES: what was typed in the Sidekick, as typed, behind a 2 pt moss edge. Every item ends with its time in moss, which plays from there and opens the transcript at that line. A voice that needs a name is a moss link that opens Who's This?. Under a hairline, the byline ("Written with GPT-6.2-Sol through Codex · Auto template · 21:50", with "asked: “…”" after an ask) and, once there are any, a moss "2 earlier versions" menu that goes back to one; the current notes take its place, so going back can be undone. The last five versions are kept.
  - While notes are written: a spinner and "I'm rewriting the notes: “Make it shorter”." over the notes at 40%; the first time, the look-down goblin at 64 pt with its quill and placeholder lines instead, since that's an empty state. A failure keeps the notes it had and says so with Try Again. "The transcript changed after I wrote these notes." (Write Again) shows only when processing ran again; a name or a spelling change never makes notes stale.
  - Before the first notes: the look-down goblin at 64 pt, "No notes for this one yet." and a moss Write Notes; before the first notes ever, the line says where the transcript goes. With no notes tool, a dashed placeholder says what to install, and the transcript opens beside the page.
  - The bar: the player strip (play, ⌥Space, the time in monospaced digits, and one 4 pt lane per voice in its colour with candle flags for marks and a moss playhead; hovering a stretch names it, clicking anywhere plays from there), then the Template popup, a capsule with the current template ("Auto"), whose menu holds the built-in templates with their one line, then Yours, then Edit Templates…; picking one rewrites the notes. Beside it a capsule field, "Tell me what to change…" ("Tell me what you want in the notes…" before there are any), with a moss send button. Focused and empty, four suggestions show above it as small capsules: Make it shorter, Only the action items, Draft a follow-up email, More detail on the decisions. An ask is sent on top of the template and can't change gob.lin's rules. The model isn't chosen here; it stays in Meeting Recording.
  - The transcript, a 320 pt panel beside the page with its own leading hairline: TRANSCRIPT, the line count and how long the audio is kept, Copy and ×, then Find in transcript. The lines are a script, not bubbles: the time in a 38 pt gutter when the speaker changes or a minute has passed, the name in the voice's colour when the speaker changes (moss for you; dashed and a Who's This? button for a voice with no name), then the words at `.row`. Marks sit between lines as candle flags. Words I respelled have a dotted moss underline, and hovering the line says "I respelled “Okafur” as Okafor." A line's context menu has Play From Here, Correct Spelling…, Put Back “Okafur” for each respelled word, and Copy Line. Clicking a line plays it, and the line playing gets the moss selection tint.
  - Correct Spelling… is a popover: the line, Heard as and Should be fields, how many lines change, "Add to the Dictionary, so dictation and later meetings spell it right" (on), Cancel and a moss Fix (Fix All 4). The person's corrections are kept apart from the notes, win over the notes' own fix of the same words, and hold when the notes are written again.
  - The title: a title the person typed wins, then a real name from the call app, then the notes' title when the call app's name is a placeholder (a Meet code, "Zoom Meeting"), then the recorded name.
- **Who's This?** A 400 pt popover from the cast line, so the page and the transcript stay in reach: "Who's This?" and how long the voice talked (and through what), LISTEN with three clips to play (its longest lines, with lines that took over mid-sentence from another voice last), each with its time in moss, which shows it in the transcript; then COULD BE, names it could be, each with a reason: first who the voice sounds like in People ("Sounds like Mira, from 2 meetings.") or another voice of this meeting (Same Voice), then the call's participant list. The first is a moss button and the default (Return); ⌘2 and ⌘3 take the others. Then a "Someone else…" field that completes from People, the call's list and this meeting's other voices, with "New person: I haven't heard of Ana Ruis before." under it when the name is new. With more than one voice to name it walks through them, longest talker first, with "1 of 3", Skip and Done. The footer says whether I'll remember the name. When the call listed fewer people than voices, a quiet "Two people on one laptop?" disclosure keeps the laptop's owner and names the second voice as a guest. In the room there's no participant list, so it offers That's Me first. Someone heard beside you on a call's mic is the same: "Speaker 3 talked for 4 min, through your mic.", no participant list and no laptop line, and That's Me only while no voice is You. Rename… opens the same popover with the name in the field.
- **Setup sheet:** "Two permissions, two choices." First run's setup plate with System Audio Recording and Notifications, the shut goblin at 128 pt gripping its top edge; then an After each call plate with two switches, both on: "Write notes after each call", whose line names the model and the company the transcript goes to (or says Codex or Claude Code is needed), and "Remember voices"; a plate saying "Tell people before I record them."; and Cancel and Turn On, which waits for System Audio Recording. While System Audio Recording is being asked for its light is amber with a line under the row: "Waiting for macOS to ask. Choose Allow and I'll notice.", then, once System Settings has been opened, "Waiting for System Settings. Flip gob.lin on. If macOS offers Quit & Reopen, say yes and I'll pick up here." Back from System Settings still without access, the line reads "Still off here. If gob.lin is already on in System Settings, macOS only tells me once I reopen." with Open Settings and a moss Reopen gob.lin. After a quit from there, the next launch opens the sheet again, its switches as they were left. Turn On with notes on is the yes to sending transcripts; with Remember voices on it turns that on.
- **Empty:** the closed goblin at 128 pt with Zz, "No calls on tape yet.", and a line on how recording starts.
- In the room, nothing says "call": no call audio, no participants, no shared laptop.

### First run

`Sources/GoblinApp/Permissions/OnboardingView.swift`. One 660 pt window, light or dark, with a step bar of lights: Permissions, Talk key, First take, then the finale.

1. **Permissions:** "Two switches, then you can talk." Match the count to the permissions `PermissionModel` requests; today that's Microphone and Accessibility.
   - The setup plate has one row per permission: a light with a label, a symbol, the name, one line on why, and the action.
   - Only the current row gets the moss tint and the primary button. While the person is in System Settings, an amber line with animated dots reads "Waiting for System Settings. Flip gob.lin on, then come back. I'll notice."
   - The shut goblin at 128 pt grips the plate's top edge.
   - The existing failure and revocation explanations become amber status rows.
2. **Talk key:** the General keycap card on its own, plus a light that turns green when the key is pressed.
3. **First take:** "Say something." and a line to read aloud: "The goblin types faster than I do." When the words land, the field gets a moss ring and the result reads "Nailed it. 7 words in 0.21 s, right where your cursor was." The cackle goblin at 64 pt grips the field. Until then Skip sits beside the disabled Continue; it cancels a practice recording that's still running and opens the finale without a take.
4. **Finale:** "You're hired."
   - The cackle goblin at 128 pt with sparkles and coins. They burst at 1× then 2× and fade over 600 ms; this is the app's one long animation.
   - The timing sentence, the field with what they said, and a menu-bar hint: "That's me, top right." After Skip there's no field, the sentence reads "From now on, hold fn in any app and talk." with fn replaced by the talk key they picked, and the sparkles and coins are already settled.
   - The goblin, the sentences and the hint sit on the window's centre line, centred in the space above the bottom row.
   - The bottom row: the tagline on the left, on a faint tint, with Open Settings and Done on the right.

## Before you call a UI change done

1. Build and run the signed app with `scripts/build.sh`.
2. Screenshot every surface you changed in light and in dark. Shoot the overlay over a light app and over a dark app. `scripts/capture-settings.sh <folder> [settings|icloud|history|meetings|popover|onboarding|overlay]` renders every surface from synthetic data without a microphone, and `scripts/check-mascot.sh` checks the overlay's sprite rules.
3. Repeat with Reduce Motion and Increase Contrast on.
4. Check the change against every rule above. Each one either holds, or the pull request says why it doesn't.

Done means every changed surface has light and dark screenshots in the pull request, and no rule is broken without a stated reason.
