import SwiftUI
import AVFoundation
import AuthenticationServices
import CryptoKit
import UniformTypeIdentifiers

@main
struct TamilTunesApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

struct LibraryTrack: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var artist: String = ""
    var duration: Int = 0
}

struct MusicCollection: Identifiable, Codable {
    var id = UUID()
    var name: String
    var source: String
    var kind: String
    var url: String
    var tracks: [LibraryTrack] = []
    var artworkURL: String? = nil
    var artist: String? = nil
}

struct DownloadItem: Identifiable {
    let id: UUID
    let title: String
    let url: String
    var state: String
    var filename: String?
}

@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()
    @Published var collections: [MusicCollection] = []
    @Published var downloads: [DownloadItem] = []
    @Published var savedFiles: [String] = []
    @Published var notice: String?
    @Published var importing = false
    private let collectionKey = "TamilTunes.collections.v1"
    private let fileIndexName = "tamiltunes-file-index.json"
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var indexURL: URL { directory.appendingPathComponent(fileIndexName) }

    private init() {
        if let data = UserDefaults.standard.data(forKey: collectionKey),
           let decoded = try? JSONDecoder().decode([MusicCollection].self, from: data) {
            collections = decoded
        }
        refreshFiles()
    }

    func saveCollection(name: String, source: String, kind: String, url: String) {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let parsed = URL(string: link), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host != nil else {
            notice = "Enter a name and valid web link."
            return
        }
        if collections.contains(where: { $0.url == link }) {
            notice = "This collection link has already been saved."
            return
        }
        collections.insert(MusicCollection(name: name, source: source, kind: kind, url: link), at: 0)
        persistCollections()
        notice = "Saved to Playlists & Albums without downloading audio."
    }

    func importAppleAlbum(_ link: String) async {
        guard let url = URL(string: link),
              url.host?.lowercased() == "music.apple.com",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: "/").last,
              Int(id) != nil else {
            notice = "Paste an Apple Music album link ending in its numeric album ID."
            return
        }
        importing = true
        defer { importing = false }
        do {
            let endpoint = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=song&limit=200")!
            let (data, _) = try await URLSession.shared.data(from: endpoint)
            let decoded = try JSONDecoder().decode(ITunesLookup.self, from: data)
            guard let album = decoded.results.first(where: { $0.wrapperType == "collection" }) else {
                notice = "No public album metadata was returned for this link."
                return
            }
            let tracks = decoded.results.filter { $0.wrapperType == "track" }.map {
                LibraryTrack(title: $0.trackName ?? "Unknown track", url: $0.trackViewUrl ?? "",
                             artist: $0.artistName ?? "", duration: ($0.trackTimeMillis ?? 0) / 1000)
            }
            if collections.contains(where: { $0.url == link }) {
                notice = "This album is already in your library."
                return
            }
            collections.insert(MusicCollection(name: album.collectionName ?? "Album",
                source: "Apple Music", kind: "Album", url: link, tracks: tracks,
                artworkURL: album.artworkUrl100?.replacingOccurrences(of: "100x100", with: "600x600"),
                artist: album.artistName), at: 0)
            persistCollections()
            notice = "Imported \(tracks.count) album tracks and artwork. No audio downloaded."
        } catch {
            notice = "Album lookup failed: \(error.localizedDescription)"
        }
    }

    func upsertImportedCollection(_ collection: MusicCollection) {
        collections.removeAll { $0.url == collection.url }
        collections.insert(collection, at: 0)
        persistCollections()
    }

    func removeCollections(at offsets: IndexSet) {
        collections.remove(atOffsets: offsets)
        persistCollections()
    }

    private func persistCollections() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: collectionKey)
        }
    }

    private func readIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return index
    }

    private func writeIndex(_ index: [String: String]) {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func refreshFiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        savedFiles = urls.filter { $0.lastPathComponent != fileIndexName && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent).sorted()
    }

    func localURL(for filename: String) -> URL { directory.appendingPathComponent(filename) }

    func removeFile(_ filename: String) {
        try? FileManager.default.removeItem(at: localURL(for: filename))
        var index = readIndex()
        index = index.filter { $0.value != filename }
        writeIndex(index)
        refreshFiles()
    }

    private let trackSourceKey = "TamilTunes.trackSources.v1"
    func rememberedAudioSource(for track: LibraryTrack) -> String? {
        (UserDefaults.standard.dictionary(forKey: trackSourceKey) as? [String: String])?[track.id.uuidString]
    }
    func quickDownload(_ track: LibraryTrack) {
        if fileForTrack(track) != nil {
            notice = "This song is already available offline."
        } else if let source = rememberedAudioSource(for: track) {
            downloadAuthorizedAudio(source, for: track)
        } else {
            notice = "No authorized audio source is available for automatic download. Add a direct URL or an owned audio file first."
        }
    }
    private let trackFileKey = "TamilTunes.trackFiles.v1"

    private func trackFileMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: trackFileKey) as? [String: String] ?? [:]
    }

    func fileForTrack(_ track: LibraryTrack) -> String? {
        guard let filename = trackFileMap()[track.id.uuidString],
              FileManager.default.fileExists(atPath: localURL(for: filename).path) else { return nil }
        return filename
    }

    private func linkTrack(_ track: LibraryTrack, filename: String) {
        var map = trackFileMap()
        map[track.id.uuidString] = filename
        UserDefaults.standard.set(map, forKey: trackFileKey)
        refreshFiles()
    }

    func importOwnedAudio(_ source: URL, for track: LibraryTrack) {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        do {
            let extensionName = source.pathExtension.lowercased()
            guard ["mp3", "m4a", "aac", "flac", "wav", "aiff", "alac", "caf"].contains(extensionName) else {
                notice = "Choose a supported audio file, not a playlist or streaming link."
                return
            }
            let data = try Data(contentsOf: source)
            guard !data.isEmpty else { notice = "The selected file is empty."; return }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let identity = "sha256:" + digest
            if let existing = readIndex()[identity],
               FileManager.default.fileExists(atPath: localURL(for: existing).path) {
                linkTrack(track, filename: existing)
                notice = "Matched an existing offline file. No duplicate was created."
                return
            }
            let filename = digest + "." + extensionName
            try data.write(to: localURL(for: filename), options: .atomic)
            var index = readIndex()
            index[identity] = filename
            writeIndex(index)
            linkTrack(track, filename: filename)
            notice = "Added your audio file to the offline library for \(track.title)."
        } catch {
            notice = "Couldn't import audio: \(error.localizedDescription)"
        }
    }

    func downloadAuthorizedAudio(_ link: String, for track: LibraryTrack) {
        guard let url = URL(string: link),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !["music.apple.com", "open.spotify.com", "spotify.com", "youtube.com", "youtu.be"].contains(host),
              !host.hasSuffix(".youtube.com"), !host.hasSuffix(".spotify.com"),
              ["mp3", "m4a", "aac", "flac", "wav", "aiff", "caf"].contains(url.pathExtension.lowercased()) else {
            notice = "Provide a direct HTTPS audio-file URL you are authorized to download."
            return
        }
        var sources = UserDefaults.standard.dictionary(forKey: trackSourceKey) as? [String: String] ?? [:]
        sources[track.id.uuidString] = url.absoluteString
        UserDefaults.standard.set(sources, forKey: trackSourceKey)
        let identity = url.absoluteString
        if let existing = readIndex()[identity],
           FileManager.default.fileExists(atPath: localURL(for: existing).path) {
            linkTrack(track, filename: existing)
            notice = "Linked the existing offline file to \(track.title)."
            return
        }
        if activeTasks[identity] != nil {
            notice = "This audio file is already downloading."
            return
        }
        let id = UUID()
        downloads.insert(DownloadItem(id: id, title: track.title, url: identity, state: "Downloading"), at: 0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporary, response, error in
            guard let temporary, error == nil, let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  (response.mimeType?.hasPrefix("audio/") == true ||
                   response.mimeType == "application/octet-stream") else {
                Task { @MainActor in
                    self?.complete(id: id, identity: identity, filename: nil,
                                   error: error?.localizedDescription ?? "Server did not return an audio file")
                }
                return
            }
            let filename = id.uuidString + "." + url.pathExtension.lowercased()
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                Task { @MainActor in
                    self?.complete(id: id, identity: identity, filename: filename, error: nil)
                    self?.linkTrack(track, filename: filename)
                }
            } catch {
                Task { @MainActor in
                    self?.complete(id: id, identity: identity, filename: nil, error: error.localizedDescription)
                }
            }
        }
        activeTasks[identity] = task
        task.resume()
    }

    func download(url string: String) {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !["youtube.com", "youtu.be", "music.youtube.com", "spotify.com", "open.spotify.com", "music.apple.com"].contains(host),
              !host.hasSuffix(".youtube.com"), !host.hasSuffix(".spotify.com") else {
            notice = "Use a direct HTTPS file URL from a source you are permitted to download. Streaming-service links are metadata only."
            return
        }
        let identity = url.absoluteString
        if let filename = readIndex()[identity], FileManager.default.fileExists(atPath: localURL(for: filename).path) {
            notice = "Already downloaded. Reusing the existing audio file."
            return
        }
        if activeTasks[identity] != nil {
            notice = "This file is already downloading."
            return
        }
        let id = UUID()
        let title = url.deletingPathExtension().lastPathComponent.isEmpty ? host : url.deletingPathExtension().lastPathComponent
        downloads.insert(DownloadItem(id: id, title: title, url: identity, state: "Downloading"), at: 0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            // Move the URLSession temporary file before leaving its completion handler.
            guard let temporaryURL, error == nil,
                  let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                Task { @MainActor in self?.complete(id: id, identity: identity, filename: nil, error: error?.localizedDescription ?? "Download failed") }
                return
            }
            let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
            let filename = id.uuidString + "." + ext
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                Task { @MainActor in self?.complete(id: id, identity: identity, filename: filename, error: nil) }
            } catch {
                Task { @MainActor in self?.complete(id: id, identity: identity, filename: nil, error: error.localizedDescription) }
            }
        }
        activeTasks[identity] = task
        task.resume()
    }

    private func complete(id: UUID, identity: String, filename: String?, error: String?) {
        activeTasks[identity] = nil
        guard let offset = downloads.firstIndex(where: { $0.id == id }) else { return }
        if let filename {
            downloads[offset].state = "Completed"
            downloads[offset].filename = filename
            var index = readIndex()
            index[identity] = filename
            writeIndex(index)
            refreshFiles()
        } else {
            downloads[offset].state = error ?? "Failed"
        }
    }
}


@MainActor
final class SpotifyImporter: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyImporter()
    @Published var busy = false
    @Published var message: String?
    private var session: ASWebAuthenticationSession?
    private let redirect = "tamiltunes://spotify-callback"
    private var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
    func previewPublicLink(_ link: String) async {
        guard let url = URL(string: link),
              url.scheme == "https",
              url.host?.lowercased() == "open.spotify.com",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: "/"),
              path.count >= 2,
              ["playlist", "album"].contains(String(path[0])) else {
            message = "Paste a public Spotify playlist or album URL from open.spotify.com."
            return
        }
        busy = true
        defer { busy = false }
        do {
            var endpoint = URLComponents(string: "https://open.spotify.com/oembed")!
            endpoint.queryItems = [URLQueryItem(name: "url", value: link)]
            let (data, response) = try await URLSession.shared.data(from: endpoint.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                message = "Spotify couldn't provide a public preview for this link."
                return
            }
            let preview = try JSONDecoder().decode(SpotifyOEmbed.self, from: data)
            let collection = MusicCollection(name: preview.title, source: "Spotify",
                kind: path[0] == "album" ? "Album" : "Playlist",
                url: link, tracks: [], artworkURL: preview.thumbnail_url, artist: nil)
            if MusicStore.shared.collections.contains(where: { $0.url == link && !$0.tracks.isEmpty }) {
                message = "This Spotify collection already has imported tracks in your Library."
                return
            }
            MusicStore.shared.upsertImportedCollection(collection)
            message = "Added Spotify \(collection.kind.lowercased()) preview to Library. Spotify's public preview does not include a song list. For eligible playlists, use Sign in & import tracks."
        } catch {
            message = "Couldn't load Spotify preview: \(error.localizedDescription)"
        }
    }
    func importPlaylist(_ link: String) async {
        guard !clientID.isEmpty else {
            message = "Spotify sign-in is not configured in this build yet. Please contact the app developer."
            return
        }
        guard let url = URL(string: link),
              url.host?.lowercased() == "open.spotify.com",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: "/"),
              let index = parts.firstIndex(of: "playlist"), parts.indices.contains(index + 1) else {
            message = "Paste a Spotify playlist link from open.spotify.com."
            return
        }
        let playlistID = String(parts[index + 1])
        busy = true
        defer { busy = false }
        do {
            let token = try await authenticate()
            let info: SpotifyPlaylistInfo = try await request("https://api.spotify.com/v1/playlists/\(playlistID)", token: token)
            var tracks: [LibraryTrack] = []
            var next: String? = "https://api.spotify.com/v1/playlists/\(playlistID)/items?limit=50"
            var pages = 0
            while let pageURL = next, pages < 100 {
                let page: SpotifyPlaylistItems = try await request(pageURL, token: token)
                for entry in page.items {
                    guard let item = entry.item ?? entry.track, item.type == "track" else { continue }
                    tracks.append(LibraryTrack(title: item.name, url: item.external_urls?.spotify ?? "",
                        artist: item.artists?.map(\.name).joined(separator: ", ") ?? "",
                        duration: (item.duration_ms ?? 0) / 1000))
                }
                next = page.next
                pages += 1
            }
            let collection = MusicCollection(name: info.name, source: "Spotify", kind: "Playlist",
                url: link, tracks: tracks, artworkURL: info.images?.first?.url,
                artist: info.owner?.display_name)
            MusicStore.shared.upsertImportedCollection(collection)
            message = "Imported \(tracks.count) Spotify playlist tracks. Audio was not downloaded."
        } catch {
            message = "Spotify import failed: \(error.localizedDescription)"
        }
    }
    private func authenticate() async throws -> String {
        let verifier = (0..<64).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".randomElement()! }
            .reduce(into: "") { $0.append($1) }
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "playlist-read-private playlist-read-collaborative")
        ]
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "tamiltunes") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? SpotifyImportError.invalidResponse) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: SpotifyImportError.invalidResponse) }
        }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard values.first(where: { $0.name == "state" })?.value == state,
              let code = values.first(where: { $0.name == "code" })?.value else {
            throw SpotifyImportError.invalidResponse
        }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        var encoded = URLComponents()
        encoded.queryItems = body
        request.httpBody = Data((encoded.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpotifyImportError.invalidResponse }
        return try JSONDecoder().decode(SpotifyToken.self, from: data).access_token
    }
    private func request<T: Decodable>(_ url: String, token: String) async throws -> T {
        guard let address = URL(string: url), address.scheme == "https",
              address.host == "api.spotify.com" else { throw SpotifyImportError.invalidResponse }
        var request = URLRequest(url: address)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpotifyImportError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
enum SpotifyImportError: Error { case invalidResponse }
struct SpotifyOEmbed: Decodable { let title: String; let thumbnail_url: String? }
struct SpotifyToken: Decodable { let access_token: String }
struct SpotifyImage: Decodable { let url: String }
struct SpotifyOwner: Decodable { let display_name: String? }
struct SpotifyPlaylistInfo: Decodable {
    let name: String
    let images: [SpotifyImage]?
    let owner: SpotifyOwner?
}
struct SpotifyArtist: Decodable { let name: String }
struct SpotifyExternal: Decodable { let spotify: String? }
struct SpotifyTrack: Decodable {
    let type: String?
    let name: String
    let artists: [SpotifyArtist]?
    let duration_ms: Int?
    let external_urls: SpotifyExternal?
}
struct SpotifyPlaylistEntry: Decodable {
    let item: SpotifyTrack?
    let track: SpotifyTrack?
}
struct SpotifyPlaylistItems: Decodable {
    let items: [SpotifyPlaylistEntry]
    let next: String?
}

struct ITunesLookup: Decodable {
    let results: [ITunesEntry]
}
struct ITunesEntry: Decodable {
    let wrapperType: String?
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let artworkUrl100: String?
    let trackViewUrl: String?
    let trackTimeMillis: Int?
}

enum TuneStyle {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.085)
    static let panel = Color(red: 0.12, green: 0.13, blue: 0.17)
    static let accent = Color(red: 1, green: 0.29, blue: 0.45)
    static let muted = Color(red: 0.63, green: 0.65, blue: 0.72)
}

struct RootView: View {
    var body: some View {
        TabView {
            HomeScreen().tabItem { Label("Listen", systemImage: "house.fill") }
            CollectionsScreen().tabItem { Label("Library", systemImage: "square.stack.fill") }
            ImportScreen().tabItem { Label("Import", systemImage: "plus.circle.fill") }
            DownloadsScreen().tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
        }
        .tint(TuneStyle.accent)
        .preferredColorScheme(.dark)
    }
}

struct CoverArt: View {
    let url: String?
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let url, let remote = URL(string: url) {
                AsyncImage(url: remote) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [TuneStyle.accent, .purple, .indigo],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: size * 0.32, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.bold()).foregroundStyle(.white)
            Text(subtitle).font(.subheadline).foregroundStyle(TuneStyle.muted)
        }
    }
}

struct HomeScreen: View {
    @ObservedObject private var store = MusicStore.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR MUSIC, YOUR WAY").font(.caption.bold())
                                .tracking(2).foregroundStyle(TuneStyle.accent)
                            Text("Good to see you.").font(.largeTitle.bold())
                        }
                        Spacer()
                        Image(systemName: "waveform").font(.title2.bold())
                            .frame(width: 48, height: 48)
                            .background(TuneStyle.panel, in: Circle())
                    }
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 26)
                            .fill(LinearGradient(colors: [Color(red: 0.47, green: 0.15, blue: 0.35),
                                                          Color(red: 0.15, green: 0.12, blue: 0.35),
                                                          TuneStyle.panel],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Circle().fill(.white.opacity(0.055)).frame(width: 260)
                            .offset(x: 170, y: -70)
                        VStack(alignment: .leading, spacing: 13) {
                            Image(systemName: "music.mic").font(.system(size: 35))
                            Spacer()
                            Text("TamilTunes").font(.system(size: 33, weight: .heavy))
                            Text("Your albums. Your playlists. One library.")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        }.padding(24)
                    }
                    .frame(height: 225).clipped()
                    SectionHeading(title: "Recently added", subtitle: "Your imported albums and playlists")
                    if store.collections.isEmpty {
                        NavigationLink(destination: ImportScreen()) {
                            HStack(spacing: 15) {
                                Image(systemName: "plus").font(.title2.bold())
                                    .frame(width: 56, height: 56)
                                    .background(TuneStyle.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Build your library").font(.headline)
                                    Text("Import your first album or playlist")
                                        .font(.subheadline).foregroundStyle(TuneStyle.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding(16)
                                .background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(store.collections.prefix(8)) { item in
                                    NavigationLink(destination: CollectionPage(collection: item)) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            CoverArt(url: item.artworkURL, size: 146)
                                            Text(item.name).font(.subheadline.bold()).lineLimit(1)
                                            Text(item.artist ?? item.source).font(.caption)
                                                .foregroundStyle(TuneStyle.muted).lineLimit(1)
                                        }.frame(width: 146, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    SectionHeading(title: "Made for your library", subtitle: "Download once, enjoy across collections")
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.title2).foregroundStyle(TuneStyle.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(store.savedFiles.count) offline files").font(.headline)
                            Text("Exact-link duplicate protection is enabled.")
                                .font(.caption).foregroundStyle(TuneStyle.muted)
                        }
                        Spacer()
                    }.padding(18).background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                }.padding(20)
            }
            .background(TuneStyle.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct ImportScreen: View {
    @ObservedObject private var store = MusicStore.shared
    @ObservedObject private var spotify = SpotifyImporter.shared
    @State private var link = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeading(title: "Bring your music in", subtitle: "Paste a collection link to get started")
                    VStack(alignment: .leading, spacing: 14) {
                        Label("MUSIC LINK", systemImage: "link").font(.caption.bold())
                            .tracking(1).foregroundStyle(TuneStyle.muted)
                        TextField("Paste Apple Music album or Spotify playlist URL", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).padding(16)
                            .background(TuneStyle.background, in: RoundedRectangle(cornerRadius: 14))
                        Button {
                            Task { await store.importAppleAlbum(link.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        } label: {
                            HStack {
                                if store.importing { ProgressView().tint(.white) }
                                else { Image(systemName: "square.and.arrow.down") }
                                Text(store.importing ? "Importing album…" : "Import Apple Music album")
                            }.font(.headline).frame(maxWidth: .infinity).padding(16)
                        }
                        .disabled(store.importing)
                        .background(TuneStyle.accent, in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.white)
                        Text("Apple Music public album metadata and track lists are fetched automatically. No audio is downloaded.")
                            .font(.footnote).foregroundStyle(TuneStyle.muted)
                    }.padding(18).background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 22))

                    Button {
                        Task { await spotify.previewPublicLink(link.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    } label: {
                        HStack {
                            if spotify.busy { ProgressView().tint(.white) }
                            else { Image(systemName: "music.note.list") }
                            Text(spotify.busy ? "Loading Spotify preview…" : "Add Spotify link without sign-in")
                        }.font(.headline).frame(maxWidth: .infinity).padding(16)
                    }
                    .disabled(spotify.busy)
                    .background(Color(red: 0.10, green: 0.60, blue: 0.34), in: RoundedRectangle(cornerRadius: 15))
                    .foregroundStyle(.white)
                    Text("Adds the public title and artwork. Spotify does not provide the full track list through its login-free preview API.")
                        .font(.footnote).foregroundStyle(TuneStyle.muted)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("How to add music", systemImage: "info.circle.fill")
                            .font(.headline).foregroundStyle(.white)
                        Text("1. Copy an album link from Apple Music or a playlist link from Spotify.")
                        Text("2. Paste the link above and tap its Import button.")
                        Text("3. For Spotify, sign in to your Spotify account when prompted.")
                        Text("4. The available metadata is added to Library. Spotify previews do not include songs.")
                        Divider().overlay(.white.opacity(0.08))
                        Text("SUPPORTED NOW").font(.caption.bold())
                            .tracking(1).foregroundStyle(TuneStyle.accent)
                        Text("Apple Music: public albums")
                        Text("Spotify: public playlist/album previews without sign-in; eligible playlist tracks with sign-in")
                        Text("YouTube and other playlist imports are not supported yet.")
                        Text("Importing saves metadata only. It never downloads streaming audio.")
                            .foregroundStyle(TuneStyle.muted)
                    }
                    .font(.subheadline)
                    .foregroundStyle(TuneStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 20))

                    Button {
                        Task { await spotify.importPlaylist(link.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    } label: {
                        Label("Sign in to Spotify & import tracks", systemImage: "person.crop.circle")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(spotify.busy)
                    .buttonStyle(.bordered)
                    .tint(.green)
                    Text("Track import requires TamilTunes' Spotify integration to be configured and a playlist you own or collaborate on.")
                        .font(.footnote).foregroundStyle(TuneStyle.muted)

                    SectionHeading(title: "Direct audio download", subtitle: "For permitted HTTPS audio file URLs")
                    Button { store.download(url: link) } label: {
                        Label("Add direct file to downloads", systemImage: "arrow.down.to.line")
                            .font(.headline).frame(maxWidth: .infinity).padding(16)
                    }.background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 15))
                    Text("This does not extract audio from Apple Music, Spotify or YouTube, and does not transcode audio.")
                        .font(.footnote).foregroundStyle(TuneStyle.muted)
                }.padding(20)
            }.background(TuneStyle.background)
                .navigationTitle("Import").navigationBarTitleDisplayMode(.large)
                .alert("Spotify", isPresented: Binding(
                    get: { spotify.message != nil },
                    set: { if !$0 { spotify.message = nil } }
                )) {
                    Button("OK", role: .cancel) { spotify.message = nil }
                } message: { Text(spotify.message ?? "") }
                .alert("TamilTunes", isPresented: Binding(
                    get: { store.notice != nil },
                    set: { if !$0 { store.notice = nil } }
                )) {
                    Button("OK", role: .cancel) { store.notice = nil }
                } message: { Text(store.notice ?? "") }
        }
    }
}

struct CollectionsScreen: View {
    @ObservedObject private var store = MusicStore.shared
    @State private var filter = "All"
    var visible: [MusicCollection] {
        store.collections.filter { filter == "All" || $0.kind == filter }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "Your collection", subtitle: "Albums and playlists, beautifully organized")
                    NavigationLink(destination: OfflineScreen()) {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.down.to.line.compact").font(.title2)
                                .foregroundStyle(TuneStyle.accent)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Offline music").font(.headline)
                                Text("Browse downloaded files").font(.caption)
                                    .foregroundStyle(TuneStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(TuneStyle.muted)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                    HStack(spacing: 8) {
                        ForEach(["All", "Album", "Playlist"], id: \.self) { value in
                            Button(value == "All" ? "All" : value + "s") { filter = value }
                                .font(.subheadline.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(filter == value ? TuneStyle.accent : TuneStyle.panel,
                                            in: Capsule())
                        }
                    }
                    if visible.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "square.stack.3d.up").font(.system(size: 48))
                                .foregroundStyle(TuneStyle.accent)
                            Text("Your music belongs here").font(.title3.bold())
                            Text("Import an album to see its artwork and track list.")
                                .foregroundStyle(TuneStyle.muted).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    ForEach(visible) { item in
                        NavigationLink(destination: CollectionPage(collection: item)) {
                            HStack(spacing: 15) {
                                CoverArt(url: item.artworkURL, size: 74)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.headline).lineLimit(2)
                                    Text("\(item.kind) · \(item.artist ?? item.source)")
                                        .font(.subheadline).foregroundStyle(TuneStyle.muted)
                                    Text("\(item.tracks.count) tracks")
                                        .font(.caption).foregroundStyle(TuneStyle.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(TuneStyle.muted)
                            }.padding(12)
                                .background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }.background(TuneStyle.background)
                .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct CollectionPage: View {
    let collection: MusicCollection
    @ObservedObject private var store = MusicStore.shared
    @State private var selectedTrack: LibraryTrack?
    @State private var showingFilePicker = false
    @State private var showingURLSheet = false
    @State private var audioLink = ""
    @State private var playingFile: SelectedAudio?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CoverArt(url: collection.artworkURL, size: 210)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 12)
                Text(collection.name).font(.title.bold()).multilineTextAlignment(.center)
                Text(collection.artist ?? collection.source).foregroundStyle(TuneStyle.muted)
                Text("\(collection.tracks.count) tracks · \(collection.source)")
                    .font(.caption).foregroundStyle(TuneStyle.muted)
                if collection.tracks.isEmpty {
                    Text("No track list available for this collection.")
                        .foregroundStyle(TuneStyle.muted).padding(24)
                } else {
                    Text("Tap a song to attach an audio file you own or a permitted direct download. Importing album metadata does not provide Apple Music audio.")
                        .font(.footnote).foregroundStyle(TuneStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(collection.tracks.enumerated()), id: \.element.id) { index, track in
                    Button { selectedTrack = track } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").foregroundStyle(TuneStyle.muted).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.subheadline.bold()).foregroundStyle(.white)
                                Text(track.artist).font(.caption).foregroundStyle(TuneStyle.muted)
                            }
                            Spacer(minLength: 4)
                        }.frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    Divider().overlay(.white.opacity(0.06))
                }
            }.padding(20).frame(maxWidth: .infinity)
        }
        .background(TuneStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(selectedTrack?.title ?? "Audio options",
                            isPresented: Binding(get: { selectedTrack != nil },
                                                 set: { if !$0 { selectedTrack = nil } }),
                            titleVisibility: .visible) {
            if let track = selectedTrack {
                if let filename = store.fileForTrack(track) {
                    Button("Play offline") {
                        playingFile = SelectedAudio(name: filename)
                        selectedTrack = nil
                    }
                }
                Button("Download") {
                    store.quickDownload(track)
                    selectedTrack = nil
                }
                Button("Choose audio file from Files") {
                    showingFilePicker = true
                }
                Button("Download from authorized direct URL") {
                    audioLink = ""
                    showingURLSheet = true
                }
            }
            Button("Cancel", role: .cancel) { selectedTrack = nil }
        } message: {
            Text("Apple Music catalog audio cannot be downloaded as a standalone file.")
        }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result, let track = selectedTrack {
                store.importOwnedAudio(url, for: track)
            } else if case .failure(let error) = result {
                store.notice = error.localizedDescription
            }
            selectedTrack = nil
        }
        .sheet(isPresented: $showingURLSheet, onDismiss: { selectedTrack = nil }) {
            NavigationStack {
                Form {
                    Text("Only use direct HTTPS audio files you have permission to download. Apple Music links and preview URLs are not downloadable audio.")
                    TextField("https://example.com/song.flac", text: $audioLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Add to download queue") {
                        if let track = selectedTrack {
                            store.downloadAuthorizedAudio(audioLink, for: track)
                        }
                        showingURLSheet = false
                    }
                }
                .navigationTitle("Download audio")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingURLSheet = false }
                    }
                }
            }.presentationDetents([.medium])
        }
        .sheet(item: $playingFile) { item in
            LocalPlayer(url: store.localURL(for: item.name), title: item.name)
        }
        .alert("TamilTunes", isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button("OK", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}

struct DownloadsScreen: View {
    @ObservedObject private var store = MusicStore.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "Download activity", subtitle: "Your direct-file transfer queue")
                    if store.downloads.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 50))
                                .foregroundStyle(TuneStyle.accent)
                            Text("Nothing downloading yet").font(.title3.bold())
                            Text("Add a permitted direct audio link from Import.")
                                .foregroundStyle(TuneStyle.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    ForEach(store.downloads) { item in
                        HStack(spacing: 14) {
                            Image(systemName: item.state == "Completed" ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.title2).foregroundStyle(TuneStyle.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline)
                                Text(item.state).font(.caption).foregroundStyle(TuneStyle.muted)
                            }
                            Spacer()
                        }.padding(16).background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                    }
                }.padding(20)
            }.background(TuneStyle.background)
                .navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct OfflineScreen: View {
    @ObservedObject private var store = MusicStore.shared
    @State private var selected: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "Offline music", subtitle: "Audio stored on this iPhone")
                    HStack {
                        Image(systemName: "internaldrive").foregroundStyle(TuneStyle.accent)
                        Text("\(store.savedFiles.count) downloaded files").font(.headline)
                        Spacer()
                    }.padding(18).background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                    if store.savedFiles.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "music.note.list").font(.system(size: 50))
                                .foregroundStyle(TuneStyle.accent)
                            Text("Your offline library is empty").font(.title3.bold())
                            Text("Download an authorized audio file to listen offline.")
                                .foregroundStyle(TuneStyle.muted).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    ForEach(store.savedFiles, id: \.self) { file in
                        HStack(spacing: 12) {
                            CoverArt(url: nil, size: 54)
                            Text(file).font(.subheadline).lineLimit(2)
                            Spacer()
                            Button { selected = file } label: {
                                Image(systemName: "play.circle.fill").font(.title2)
                            }
                            Button(role: .destructive) { store.removeFile(file) } label: {
                                Image(systemName: "trash").foregroundStyle(TuneStyle.muted)
                            }
                        }.padding(10).background(TuneStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(20)
            }.background(TuneStyle.background)
                .navigationTitle("Offline").navigationBarTitleDisplayMode(.inline)
                .sheet(item: Binding(
                    get: { selected.map { SelectedAudio(name: $0) } },
                    set: { selected = $0?.name }
                )) { item in
                    LocalPlayer(url: store.localURL(for: item.name), title: item.name)
                }
        }
    }
}

struct SelectedAudio: Identifiable {
    let name: String
    var id: String { name }
}

struct LocalPlayer: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playing = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(.pink)
                Text(title).font(.headline)
                Button {
                    if playing { player?.pause() }
                    else {
                        if player == nil { player = AVPlayer(url: url) }
                        player?.play()
                    }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                Text("Playback requires an iOS-supported audio format.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
                .navigationTitle("Now Playing")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { player?.pause(); dismiss() }
                    }
                }
        }.onDisappear { player?.pause() }
    }
}
