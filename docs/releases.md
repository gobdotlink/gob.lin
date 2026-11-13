# Releases and updates

gob.lin ships on GitHub Releases as a disk image for first installs and one
versioned ZIP for updates, with an hourly in-app check, GitHub CLI authentication with a saved token fallback,
and an explicit install-and-relaunch action. There is no appcast, Sparkle dependency,
scheduled publisher, or update service to operate.

## Install and authenticate

Releases of `gobdotlink/gob.lin` are public and need no authentication.
If the GitHub CLI is signed in, the app uses that authentication; otherwise it uses a
token saved in Settings → About, and with neither it checks anonymously. The token is
saved in gob.lin preferences separately from rewrite keys. The app looks for `gh` in
`/opt/homebrew/bin` and `/usr/local/bin`, so launching from Finder works too.

For a first install:

```sh
gh release download --repo gobdotlink/gob.lin --pattern 'gob.lin-*.zip' --dir /tmp/goblin-release
ditto -xk /tmp/goblin-release/gob.lin-0.1.1.zip /tmp/goblin-release
# Quit any existing gob.lin first; copy the extracted gob.lin.app to Applications.
```

Use the actual downloaded version in the extraction command. Release ZIPs are built
on the Release workflow's Apple silicon runner and run on Apple silicon only.
The updater rejects a bundle that cannot run on the receiving Mac or macOS version.

## Signing

Releases are signed with a Developer ID Application certificate, notarized by Apple
and stapled, so a downloaded copy opens without **Open Anyway**. Developer ID builds
use Apple's default designated requirement, which names the team rather than one
certificate: a renewed certificate from the same team still updates existing
installations and keeps their privacy grants. A signed update is checked against
the installed app's designated requirement before any replacement. ZIP size,
optional GitHub SHA-256 digest, bundle ID, executable name, release version,
architecture and minimum macOS are checked too. Unsigned, ad-hoc, tampered,
mismatched and incompatible updates fail without replacing the app. Archive entries
cannot escape the expected bundle or introduce symlinks. Dependency resource bundles
ship inside the archive.

Developer ID builds also embed `Resources/Goblin.provisionprofile` and claim the iCloud
key-value entitlement that [dictionary sync](dictionary.md#icloud-sync) needs. macOS honours
that entitlement only beside the profile Apple issued for the signing certificate, and
refuses to launch an app that claims it without one. So `scripts/build.sh` checks the
profile was issued for the certificate it is signing with, and otherwise signs without
iCloud, as development builds do: those builds work and hide iCloud sync. A renewed
certificate needs a new Developer ID profile for `app.goblin.dictation` from the developer
portal, saved over that file. `GOBLIN_PROVISIONING_PROFILE` names a different file.

History sync also needs CloudKit and push notifications. `scripts/build.sh` claims them only
when the profile lists the `iCloud.app.goblin.dictation` container, allows the CloudKit
environment, and has push notifications; otherwise it prints what's missing and signs
without History sync, whose switch then stays hidden. So the App ID needs iCloud with
CloudKit and that container, and Push Notifications, before the profile is downloaded again.
The environment is Production unless `GOBLIN_ICLOUD_ENVIRONMENT=Development`. Production
holds only the record types deployed to it from Development in the CloudKit console, so
deploy the schema before a Production build first syncs.

The dedicated local certificate from `scripts/setup-signing.sh` is for development.
Its builds pin that certificate, are not notarized and cannot update a Developer ID
installation, or be updated by one. Installations from before notarized releases
use the local certificate, so they need one manual install of a notarized release
and fresh microphone and Accessibility grants. Neither the updater nor release
scripts remove quarantine or reset privacy grants.

`scripts/package-app.sh` notarizes whenever the app is signed with Developer ID:
it submits the ZIP with `notarytool`, staples the ticket to the app, checks it with
`spctl`, then archives that stapled bundle. It also builds `gob.lin.dmg` from the
stapled app with an Applications shortcut, then signs, notarizes, staples and checks
the image the same way. Builds signed with the local certificate get the ZIP only.
Notarization reads credentials from a
`notarytool` keychain profile, `goblin-notary` unless `GOBLIN_NOTARY_PROFILE` names
another. The Release workflow creates it on its runner. To package a notarized build
on a Mac, create it once with an app-specific password from the Apple Account:

```sh
xcrun notarytool store-credentials goblin-notary --apple-id APPLE_ID --team-id TEAM_ID
```

## Publish a release

After merging a change to main, decide whether to release it. Implementing or
merging a feature does not publish it automatically. Any maintainer with write
access can release; no signing material is needed on their Mac. Install Xcode 26.3+
and Python 3, then from a clean main checkout matching origin/main:

```sh
scripts/release.sh 0.1.1
```

Choose a strictly increasing stable `major.minor.patch` version without a `v` prefix.
The command:

1. Validates the branch, clean tree, remote main, new tag and version.
2. Updates `Resources/Info.plist` and `GoblinMetadata.swift`, incrementing the build number.
3. Runs smoke checks, Swift tests, updater checks and the repository privacy scan.
4. Commits `Release v…`, creates an annotated tag and atomically pushes main and the tag.

The tag starts the Release workflow (`.github/workflows/release.yml`) on a macOS runner.
It checks the tag is on main, matches `Info.plist` and is newer than the latest release,
compiles, then loads the Developer ID certificate into a temporary keychain. It signs, notarizes and staples the app with
`scripts/package-app.sh`, and stops unless Gatekeeper accepts the result. It then creates
a draft release, uploads `gob.lin.dmg`, `gob.lin-VERSION.zip` and the ZIP's `.sha256`, and publishes it as
latest with generated notes only after uploads succeed.

The workflow's secrets live in the repository's `release` environment, which accepts
`v*` tags only: `DEVELOPER_ID_P12` (base64), `DEVELOPER_ID_P12_PASSWORD`,
`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` (an app-specific password).
Pull requests, including from forks, never receive them. Never put these values in
the repository, workflow files or logs. When the certificate is renewed or the
password revoked, replace the secrets; updates keep working because releases pin
the team, not the certificate.

`scripts/package-app.sh [output-directory]` builds, notarizes Developer ID builds and
archives without committing, pushing, tagging or publishing. `dist/` is ignored. The
Build workflow only validates builds and updater safety and has no signing secrets.

## Update behavior

The app checks the latest stable release on launch and every hour. Manual checking
and status are in the menu and Settings → About; no release yet is a normal visible
status. No update installs without choosing **Install & relaunch**. The app downloads
the exact `gob.lin-VERSION.zip` asset, strips authorization on cross-host redirects,
and verifies the extracted bundle. Staging is beside the installation for same-volume
renames, so the app and containing folder must be writable by the current user.
Translocated apps and read-only disk images cannot self-update.

Finish dictation and text insertion, retry unsaved history, and restore a recovery
clipboard before installing. The app rechecks those conditions after downloading.
Its normal shutdown drains recognition and history writes. A detached helper waits
for the old PID to exit, replaces the app at the same path, and launches it. Failed
replacement or a failed launch command restores the previous bundle. The helper
times out without replacing an app that did not exit. Install outcome is recorded
locally in `~/Library/Application Support/gob.lin/logs/update-install.log`.
History, recordings, model files, settings and credentials stay outside the bundle.

## Failures and validation

Before a version commit, failed checks restore the two version files. If push
fails, nothing is tagged remotely or published, but the release commit and tag stay
in your checkout, so rerunning the command fails. After a transient failure, push
them with `git push --atomic origin main vVERSION`. If main moved on GitHub, drop
them with `git tag -d vVERSION`, `git fetch origin` and `git reset --keep origin/main`,
which stops rather than overwrite uncommitted edits, then run the command again.
Never move an already pushed tag.

If the Release workflow fails, nothing is published. For a missing or wrong secret,
or a transient Apple or GitHub failure, fix it and re-run the failed workflow. The
workflow refuses a tag that is not newer than the latest release, so a superseded
tag never replaces a newer release. A rejected notarization prints the submission
ID; `xcrun notarytool log SUBMISSION_ID --keychain-profile goblin-notary` on a Mac
with the profile says why. If the cause needs a code change, release the fix as the
next version. If an upload fails, the release remains a draft: re-run the workflow
after deleting the draft, or upload the missing files with `gh release upload` and
publish it with `gh release edit vVERSION --repo gobdotlink/gob.lin --draft=false --latest`.

```sh
swift test
scripts/check-updates.sh
scripts/package-app.sh
scripts/check-updates.sh .build/app/gob.lin.app
```

The updater checks exercise release selection, credential redirects, checksums,
real certificate verification when a signed fixture is supplied, native AppKit
termination with async shutdown, waiting for app exit and rollback on launch failure.
They use temporary fixtures and never launch
or replace an installed app or request privacy permissions.
