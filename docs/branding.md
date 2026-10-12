# gob.lin brand assets

The original 64×64 mouth-open and mouth-closed goblin frames, hands, Workbench, and VT323 are copied from the owner’s existing brand kit. Application code is independently implemented in Swift. The palette is #57E68F on #0B0D10. Font OFL licences are bundled beside the font files.

`GoblinBrand` loads the same asset folder in SwiftPM and Xcode bundles, registers fonts per process, and renders colour menu-bar state variants. `GoblinWordmark` uses Workbench and the VT323 tagline. The GOB-12 overlay uses the same sprites when these feature branches are combined. App icons remain transparent; macOS supplies the system icon presentation.

Regenerate the icon from unchanged source pixels with `swift scripts/make-icon.swift` and `iconutil -c icns .build/Goblin.iconset -o Resources/Goblin.icns`. The generator uses nearest-neighbour drawing. Run `xcodegen generate` after changing Xcode sources/resources. `scripts/build.sh` copies assets into the signed app.

Checks: SwiftPM debug build, signed app bundle verification, and Xcode debug build. Live recording/transcribing/warning states are wired by the shared app coordinator when pipeline features are integrated.
