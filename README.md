# TamilTunes

TamilTunes is an early-stage SwiftUI iOS music-library prototype.

## What is in this repository

- SwiftUI app with **Import**, **Playlists & Albums**, **Downloads** and **Offline Library** tabs.
- Save playlist/album link references without starting downloads.
- Direct authorized HTTPS file downloads with duplicate prevention for the **exact same URL**.
- Local audio-file storage and basic AVPlayer playback.
- `project.yml` for generating an Xcode project using XcodeGen.
- `.github/workflows/release-ipa.yml` to build an **unsigned IPA** on each published GitHub Release.

## Build and release

Read [BUILDING.md](BUILDING.md). Publish a GitHub Release to trigger the build; the workflow attaches `TamilTunes-unsigned.ipa` on success. You can also launch it manually from the Actions tab.

**Unsigned IPAs are not installable on an ordinary iPhone.** Secure distribution signing and provisioning are not yet configured. The first CI run has not yet been verified.

## Still in development

Apple Music, Spotify and YouTube collection metadata integrations are not connected. Provider audio extraction is not supported. Cross-source deduplication (ISRC/audio fingerprint) is not implemented. The direct URL downloader does not transcode formats. This is a working source-code foundation, not a finished app.
