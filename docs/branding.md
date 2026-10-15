# gob.lin brand assets

The original 64×64 mouth-open and mouth-closed goblin frames, Workbench, and VT323 are copied from the owner’s existing brand kit. The extra expressions, hands and props (`goblin-look`, `-squint`, `-side`, `-closed`, `-sheepish`, `-cackle`, `hand-grip`, `hand-palm`, `hand-quill`, `prop-*`) were drawn for this project on the same head and palette; DESIGN.md says when each appears. Application code is independently implemented in Swift. Colour tokens live in `GoblinBrand` and are listed in DESIGN.md. Font OFL licences are bundled beside the font files.

`GoblinBrand` loads the same asset folder in SwiftPM and Xcode bundles, registers fonts per process, and renders colour menu-bar state variants. `Sprite` and `PixelSprite` draw every frame at whole-number scales with nearest-neighbour sampling. `GoblinWordmark` is Workbench alone; `GoblinTagline` is the VT323 tagline, shown only on About and at the end of first run. App icons remain transparent; macOS supplies the system icon presentation.

Finder and Get Info use the bundled `Goblin.icns`; the running menu-bar item uses the colour goblin sprite. The app intentionally has no Dock entry (`LSUIElement` and accessory activation). Missing or undecodable sprites show a green “g” fallback rather than an invisible item and emit an error under subsystem `app.goblin.dictation.brand`, category `resources`. The error names only the bundled asset, without a filesystem path.

Run `scripts/check-icons.sh /path/to/gob.lin.app [...]` against the signed shell and Xcode bundles. It verifies signatures, source-identical packaged artwork, visible icon sizes, menu states at 1×/2×, and missing/corrupt-resource fallback rendering without launching the app or requesting permissions. Native evidence and remaining limits are recorded in `docs/evidence/gob-37/verification.md`.

Regenerate the icon from unchanged source pixels with `swift scripts/make-icon.swift` and `iconutil -c icns .build/Goblin.iconset -o Resources/Goblin.icns`. The generator uses nearest-neighbour drawing. Run `xcodegen generate` after changing Xcode sources/resources. `scripts/build.sh` copies assets into the signed app.

Checks: SwiftPM debug build, signed app bundle verification, and Xcode debug build. Live recording/transcribing/warning states are wired by the shared app coordinator when pipeline features are integrated.
