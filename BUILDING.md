# TamilTunes CI and IPA packaging

Each **published GitHub Release** triggers `.github/workflows/release-ipa.yml` on a macOS runner. You can also run it manually from Actions.

The workflow installs XcodeGen, generates `TamilTunes.xcodeproj` from `project.yml`, compiles for iPhoneOS, packages `Payload/TamilTunes.app` into `TamilTunes-unsigned.ipa`, uploads it to Actions, and attaches it to the published release. If compilation fails the job fails and no IPA is attached.

**Important:** This is an **unsigned IPA**, not an installable signed release. An Apple Developer account alone cannot make an unsigned IPA install on a device. A distribution certificate and appropriate provisioning profile, matching bundle identifier and export configuration, are required for a signed installable IPA. Do not publish signing credentials in the repository. The workflow intentionally does not claim to sign.

This app is still a starter prototype: Apple Music / Spotify / YouTube collection metadata integrations are incomplete; do not assume audio downloads from those services are supported.

To customize the app's bundle identifier, edit `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. For signed iPhone installs, a separate signing/export step with securely stored GitHub Actions secrets and the correct Apple provisioning configuration must be added and verified.
