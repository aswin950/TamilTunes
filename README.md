# TamilTunes

A SwiftUI iOS music-library prototype with a dark music-first interface.

## Screens

- **Listen:** featured hero, recently imported albums and playlists, offline summary
- **Library:** album/playlist filters, artwork, collection detail pages and track lists
- **Import:** real public Apple Music **album** metadata lookup (artwork, titles, artists, durations); login-free Spotify playlist/album previews via oEmbed, optional Spotify playlist track import via OAuth PKCE (requires app-owned Spotify Client ID)
- **Downloads:** direct authorized HTTPS audio-file transfers with same-URL duplicate prevention
- **Offline:** stored local files with basic AVPlayer playback

**Apple Music offline audio:** Open an imported album, tap a track, and choose an owned audio file from Files or enter an authorized direct HTTPS audio URL. Downloaded audio is linked to the track; identical imported files are deduplicated by SHA-256. This does not download Apple Music subscription audio. Direct URL transfers currently deduplicate by URL and have no per-byte progress display.\n\n**Limitations:** YouTube and Apple Music playlist track fetching are not implemented; saving those links is reference-only. Imported metadata does not include streaming audio. No cross-provider recording matching, full playback queue, audio transcoding, or signed IPA yet.

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

## Spotify without sign-in

Paste a public `https://open.spotify.com/playlist/...` or `https://open.spotify.com/album/...` URL and tap **Add Spotify link without sign-in**. TamilTunes uses Spotify's public oEmbed endpoint to import the link title and artwork. **This is a preview, not a track-list import**: oEmbed does not expose playlist songs. The app shows zero tracks rather than inventing them. For playlists the signed-in user owns or collaborates on, **Sign in to Spotify & import tracks** is an optional authenticated path requiring the app developer's Spotify Client ID. The preview path does not require this ID.
