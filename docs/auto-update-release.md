# Auto-Update Release Flow

MediaGetter uses Sparkle 2 with GitHub Releases as the update backend.

## Runtime defaults

- The appcast feed is fixed to `https://github.com/West-Cat-Strategy/media-getter/releases/latest/download/appcast.xml`.
- Automatic update checks are enabled by default.
- Background download and install is enabled by default when Sparkle is allowed to do so.
- Signed feeds are required, which means `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` must stay enabled together.

## Release automation

- CI runs on pushes and pull requests to `main`.
- Tagged releases run on `v*` tags.
- The release workflow:
  1. Creates or updates a draft GitHub release for the pushed tag.
  2. Imports the Developer ID certificate into a temporary keychain.
  3. Imports the Sparkle EdDSA private key into the runner keychain.
  4. Builds and exports a signed `.app`.
  5. Notarizes and staples the exported app.
  6. Packages `MediaGetter.zip`.
  7. Generates and signs `appcast.xml`.
  8. Uploads both artifacts to the draft release.
  9. Publishes the release only after the assets are present.

- Release builds derive both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from the pushed tag with the leading `v` stripped.
- XcodeGen is pinned to `2.45.4` in CI and release automation.

## Required GitHub secrets

- `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`
- `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_DEVELOPER_ID_APPLICATION_IDENTITY`
- `APPLE_TEAM_ID`
- `APPLE_NOTARY_API_KEY_ID`
- `APPLE_NOTARY_API_ISSUER_ID`
- `APPLE_NOTARY_API_KEY_P8_BASE64`
- `SPARKLE_PRIVATE_ED_KEY_FILE_BASE64`

## Sparkle key management

- The public key is committed in the app Info.plist as `SUPublicEDKey`.
- Export the private key from a trusted Mac with:

```bash
build/sparkle-tools/bin/generate_keys --account media-getter -x build/sparkle-tools/media-getter.sparkle.key
```

- Base64 encode that exported key file and store it in `SPARKLE_PRIVATE_ED_KEY_FILE_BASE64`.
- Import in CI is handled by `script/import_sparkle_private_key.sh`.

## Local dry run

```bash
xcodegen generate --spec project.yml
xcodebuild test -project MediaGetter.xcodeproj -scheme MediaGetter -configuration Debug -destination 'platform=macOS,arch=arm64' -only-testing:MediaGetterTests CODE_SIGNING_ALLOWED=NO
```

For a full release dry run, provide the signing and notarization environment variables expected by the scripts in `script/`.
