# TamilTunes

A SwiftUI iOS music-library prototype with a dark music-first interface.

## Screens

- **Listen:** featured hero, recently imported albums and playlists, offline summary
- **Library:** album/playlist filters, artwork, collection detail pages and track lists
- **Import:** real public Apple Music **album** metadata lookup (artwork, titles, artists, durations); Spotify playlist metadata import via OAuth PKCE (requires Spotify Client ID), and reference-only saving for other links
- **Downloads:** direct authorized HTTPS audio-file transfers with same-URL duplicate prevention
- **Offline:** stored local files with basic AVPlayer playback

**Limitations:** YouTube and Apple Music playlist track fetching are not implemented; saving those links is reference-only. Imported metadata does not include streaming audio. No cross-provider recording matching, full playback queue, audio transcoding, or signed IPA yet.

## CI

Every push or merge to `main` automatically builds the iOS app and publishes a **GitHub prerelease** with an **unsigned** IPA asset when the build succeeds. Manual workflow runs do the same. Releases are generated automatically; no manual release publishing is required. See [BUILDING.md](BUILDING.md) and [Actions](https://github.com/aswin950/TamilTunes/actions/workflows/release-ipa.yml).

This repository's source is the canonical app version. Do not treat mockups as real screenshots. Simulator screenshots will be added only after they are captured from a running build.

## Spotify playlist import setup

1. Create a Spotify developer app at https://developer.spotify.com/dashboard and register the exact redirect URI `tamiltunes://spotify-callback` (subject to Spotify's current redirect-URI rules).
2. Configure `SPOTIFY_CLIENT_ID` in `project.yml` with the app's **public Client ID**, or supply it as an Xcode build setting. Do not commit a Spotify client secret.
3. Build the app. Paste an `https://open.spotify.com/playlist/...` link, tap **Import Spotify playlist**, and authorize access in the browser.
4. The importer fetches playlist information and paginates through track metadata. Private playlists require appropriate user access/scopes. Spotify may limit API access based on developer app approval and mode.

Spotify authentication uses Authorization Code with PKCE. The implementation does not persist access tokens; it requests authorization for each import. Spotify audio downloading is not supported.

**Verification:** The Spotify import flow has not been exercised against a configured Spotify developer app; inspect the GitHub Actions build before relying on it.
