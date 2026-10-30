# TamilTunes

A SwiftUI iOS music-library prototype with a dark music-first interface.

## Screens

- **Listen:** featured hero, recently imported albums and playlists, offline summary
- **Library:** album/playlist filters, artwork, collection detail pages and track lists
- **Import:** real public Apple Music **album** metadata lookup (artwork, titles, artists, durations); reference-only saving for other collection links
- **Downloads:** direct authorized HTTPS audio-file transfers with same-URL duplicate prevention
- **Offline:** stored local files with basic AVPlayer playback

**Limitations:** Spotify/YouTube and Apple Music playlist track fetching are not implemented; saving those links is reference-only. Imported metadata does not include streaming audio. No cross-provider recording matching, full playback queue, audio transcoding, or signed IPA yet.

## CI

Every push or merge to `main` automatically builds the iOS app and uploads an **unsigned** IPA artifact. Publishing a GitHub Release also attaches the unsigned IPA to that release. See [BUILDING.md](BUILDING.md) and [Actions](https://github.com/aswin950/TamilTunes/actions/workflows/release-ipa.yml).

This repository's source is the canonical app version. Do not treat mockups as real screenshots. Simulator screenshots will be added only after they are captured from a running build.
