# Release signing and notarization

Tagged releases (`v*`) are signed with a Developer ID Application certificate and
notarized with Apple before being attached to the GitHub Release. Pull request and
`main` branch builds fall back to ad-hoc signing and skip notarization, so no
secrets are required for regular CI.

The signing/notarization logic lives in [`.github/scripts/package-app.sh`](../.github/scripts/package-app.sh),
invoked by the packaging steps in [`.github/workflows/release.yml`](../.github/workflows/release.yml).

## Required repository secrets

| Secret | Description |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded **Developer ID Application** certificate + private key (`.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting the `.p12` file |
| `APPLE_ID` | Apple ID email of the developer account used for notarization |
| `APPLE_APP_PASSWORD` | [App-specific password](https://support.apple.com/102654) for that Apple ID |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |

## Preparing the certificate secret

Export the "Developer ID Application: …" certificate (including its private key)
from Keychain Access as a `.p12`, then encode it:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the result into the `MACOS_CERTIFICATE_P12` secret.

## What the release pipeline does

For each of the three app variants (arm64, arm64-lite, x86_64):

1. Imports the certificate into a temporary keychain (deleted after the job).
2. Embeds the `koe-cli` binary into `Koe.app/Contents/MacOS/`.
3. Signs nested frameworks/dylibs, `koe-cli`, and the app bundle with the
   Developer ID identity, hardened runtime, secure timestamp, and the app's
   entitlements (`KoeApp/Koe/Koe.entitlements`).
4. Submits the app to Apple notary service (`notarytool submit --wait`) and fails
   the build with the notarization log if the submission is not accepted.
5. Staples the notarization ticket to the app and verifies it with
   `stapler validate` and `spctl --assess`.
6. Zips the stapled app; the release job attaches the zips to the GitHub Release.
