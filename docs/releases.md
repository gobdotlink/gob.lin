# Releases and updates

gob.lin ships as one versioned ZIP on GitHub Releases, with
an hourly in-app check, GitHub CLI authentication with a saved token fallback,
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

Use the actual downloaded version in the extraction command. Release ZIPs target
the architecture of the publishing Mac (Apple Silicon for the current release host).
The updater rejects a bundle that cannot run on the receiving Mac or macOS version.

## Signing

`scripts/build.sh` keeps using its stable certificate and designated requirement.
The same identity must sign every release for an existing installation. A signed
update is checked against the installed app's designated requirement, including its
certificate, before any replacement. ZIP size, optional GitHub SHA-256 digest,
bundle ID, executable name, release version, architecture and minimum macOS are
checked too. Unsigned, ad-hoc, tampered, mismatched and incompatible updates fail
without replacing the app. Archive entries cannot escape the expected bundle or
introduce symlinks. Dependency resource bundles ship inside the archive.

The dedicated local certificate supports trusted internal development installs.
Keep its private key and reuse it on the release host; do not commit or upload it.
A different developer's newly generated certificate cannot update this installation.
For broad public distribution, use a consistent Developer ID identity via
`GOBLIN_SIGNING_IDENTITY`, notarize and staple the app, then archive that exact
stapled bundle. The current release command does **not** notarize. Do not present
locally signed builds as notarized public downloads. Changing signing identity
requires a manual trusted install and may require granting macOS permissions again.
Neither the updater nor release scripts remove quarantine or reset privacy grants.

## Publish a release

After merging a change to main, decide whether to release it. Implementing or
merging a feature does not publish it automatically. On the release Mac, install
Xcode 26.3+, Python 3 and `gh`, authenticate with repository write access, and ensure
the signing certificate is available in the login keychain. From a clean main
checkout matching origin/main:

```sh
scripts/release.sh 0.1.1
```

Choose a strictly increasing stable `major.minor.patch` version without a `v` prefix.
The command:

1. Validates the branch, clean tree, remote main, authentication, new tag and version.
2. Updates `Resources/Info.plist` and `GoblinMetadata.swift`, incrementing the build number.
3. Runs smoke checks, Swift tests, updater checks and the repository privacy scan.
4. Commits `Release v…`, builds that clean commit, signs the app and creates
   `dist/gob.lin-VERSION.zip` plus its `.sha256` file.
5. Creates an annotated tag and atomically pushes main and the tag.
6. Creates a draft GitHub release, uploads both files, and publishes it as latest
   with generated release notes only after uploads succeed.

`scripts/package-app.sh [output-directory]` builds and archives without committing,
pushing, tagging or publishing. `dist/` is ignored. The release command is the
publisher; CI only validates builds and updater safety and needs no signing secrets.

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

Before a version commit, failed checks restore the two version files. After the
commit, failures leave the release commit intact for inspection. If packaging
fails, fix the cause and rerun `scripts/package-app.sh`; then create/push the
annotated tag for that exact release commit. If push fails, no release is published;
resolve the remote state before retrying. Never move an already published tag.
If an upload fails, the release remains a draft: verify the tag and artifact, upload
the missing ZIP/checksum with `gh release upload`, then publish that draft with
`gh release edit vVERSION --repo gobdotlink/gob.lin --draft=false --latest`.
Do not bump to another version merely to recover an unpublished draft.

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
