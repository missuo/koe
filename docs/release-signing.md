# Release signing, notarization, and Sparkle updates

Tagged releases (`v*`) are signed with a Developer ID Application certificate,
notarized with Apple, and published to Sparkle appcasts before being attached to
the GitHub Release. Pull request and `main` branch builds fall back to ad-hoc
signing and skip notarization and Sparkle signing, so no secrets are required
for regular CI.

The signing/notarization logic lives in [`.github/scripts/package-app.sh`](../.github/scripts/package-app.sh),
invoked by the packaging steps in [`.github/workflows/release.yml`](../.github/workflows/release.yml).
Appcast publication is handled by [`.github/scripts/update-feeds.py`](../.github/scripts/update-feeds.py).

## Required repository secrets

| Secret | Description |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded **Developer ID Application** certificate + private key (`.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting the `.p12` file |
| `APPLE_ID` | Apple ID email of the developer account used for notarization |
| `APPLE_APP_PASSWORD` | [App-specific password](https://support.apple.com/102654) for that Apple ID |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `SPARKLE_ED25519_PUBLIC_KEY` | Sparkle EdDSA public key (base64), injected into `SUPublicEDKey` at build time |
| `SPARKLE_ED25519_PRIVATE_KEY` | Sparkle EdDSA private key (base64), used by `sign_update` to sign the release zips |

## Generating the Sparkle EdDSA keypair (one-time)

Download the [Sparkle distribution](https://github.com/sparkle-project/Sparkle/releases)
and run its `generate_keys` tool:

```sh
./bin/generate_keys            # generates a keypair in the login keychain, prints the public key
./bin/generate_keys -x key.txt # exports the private key to key.txt for the secret
```

Store the printed public key as `SPARKLE_ED25519_PUBLIC_KEY` and the contents of
`key.txt` as `SPARKLE_ED25519_PRIVATE_KEY`, then delete `key.txt`.

## Preparing the certificate secret

Export the "Developer ID Application: …" certificate (including its private key)
from Keychain Access as a `.p12`, then encode it:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the result into the `MACOS_CERTIFICATE_P12` secret.

## What the release pipeline does

For both app variants (Koe and Koe MLX, Apple Silicon only):

1. Imports the certificate into a temporary keychain (deleted after the job) and
   injects `SUPublicEDKey` into the Info.plist.
2. Embeds the `koe-cli` binary into `Koe.app/Contents/MacOS/`.
3. Signs Sparkle's helpers and XPC services, nested frameworks/dylibs, `koe-cli`,
   and the app bundle with the Developer ID identity, hardened runtime, secure
   timestamp, and the app's entitlements (`KoeApp/Koe/Koe.entitlements`).
4. Submits the app to Apple notary service (`notarytool submit --wait`) and fails
   the build with the notarization log if the submission is not accepted.
5. Staples the notarization ticket to the app and verifies it with
   `stapler validate` and `spctl --assess`.
6. Zips the stapled app and signs the zip with Sparkle's `sign_update`, emitting
   a `<zip>.sparkle.json` metadata file.

The release job then attaches the zips to the GitHub Release and (for
non-prerelease tags) inserts a new item into each variant's appcast —
`docs/appcast.xml` (Koe) and `docs/appcast-mlx.xml` (Koe MLX) — and refreshes
the legacy `docs/update-feed.json` for pre-Sparkle builds, committing the
result to `main`. The legacy feed points at the MLX zip because the old
single-feed download was the full (MLX) build.

## Sparkle update channels

Each variant checks its own appcast (set per target via `APP_APPCAST_URL` in
`KoeApp/project.yml`), so standard users stay on standard builds and MLX users
stay on MLX builds. `CFBundleVersion` in `KoeApp/Koe/Info.plist` is Sparkle's
update ordinal — keep bumping it (together with `CFBundleShortVersionString`)
for every release.
