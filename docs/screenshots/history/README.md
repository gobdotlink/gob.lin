These captures use the production Settings/History views with an isolated temporary store and synthetic text. They show populated history, search selecting a matching recording, no matches, and empty history. They contain no user recordings or transcripts.

The file-only capture uses hidden AppKit windows. Sidebar material does not render in this path, and hidden split-pane resizing is not reliable. These are partial offscreen content evidence, not native navigation or minimum-size acceptance. The retention form was compiled and captured separately but its hidden rendering was not suitable for a retained image.

Run `scripts/check-history-layout.sh` under the shared compute resource lock. The check never activates a window, captures microphone audio, or uses the general clipboard. Menu routing, native resizing, retention sheet presentation, playback, copy, star, reprocessing, delete confirmation, and unsaved recovery still require coordinated native verification.
