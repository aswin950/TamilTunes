import SwiftUI
import AVFoundation

@main
struct TamilTunesApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

struct LibraryTrack: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct MusicCollection: Identifiable, Codable {
    var id = UUID()
    var name: String
    var source: String
    var kind: String
    var url: String
    var tracks: [LibraryTrack] = []
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

struct RootView: View {
    var body: some View {
        TabView {
            ImportScreen().tabItem { Label("Import", systemImage: "square.and.arrow.down") }
            CollectionsScreen().tabItem { Label("Playlists & Albums", systemImage: "rectangle.stack") }
            DownloadsScreen().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            OfflineScreen().tabItem { Label("Offline", systemImage: "music.note.list") }
        }
        .tint(.pink)
    }
}

struct ImportScreen: View {
    @ObservedObject private var store = MusicStore.shared
    @State private var url = ""
    @State private var name = ""
    @State private var source = "Apple Music"
    @State private var kind = "Playlist"
    private let sources = ["Apple Music", "Spotify", "YouTube", "Direct link"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Import playlist or album metadata") {
                    TextField("Playlist or album name", text: $name)
                    TextField("Link", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker("Source", selection: $source) {
                        ForEach(sources, id: \.self) { Text($0) }
                    }
                    Picker("Type", selection: $kind) {
                        Text("Playlist").tag("Playlist")
                        Text("Album").tag("Album")
                    }
                    Button("Save collection without downloading") {
                        store.saveCollection(name: name, source: source, kind: kind, url: url)
                    }
                    Text("This prototype saves collection links. Provider API track-list importing is not yet connected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Direct authorized audio file") {
                    Button("Download direct URL") { store.download(url: url) }
                    Text("Only a permitted direct HTTPS audio file is supported. This action does not convert file formats or download streaming-service content.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("TamilTunes")
            .alert("TamilTunes", isPresented: Binding(
                get: { store.notice != nil },
                set: { if !$0 { store.notice = nil } }
            )) {
                Button("OK", role: .cancel) { store.notice = nil }
            } message: {
                Text(store.notice ?? "")
            }
        }
    }
}

struct CollectionsScreen: View {
    @ObservedObject private var store = MusicStore.shared
    var body: some View {
        NavigationStack {
            List {
                if store.collections.isEmpty {
                    ContentUnavailableView("No collections yet", systemImage: "rectangle.stack",
                        description: Text("Save a playlist or album link from Import."))
                }
                ForEach(store.collections) { collection in
                    NavigationLink {
                        List {
                            LabeledContent("Source", value: collection.source)
                            LabeledContent("Kind", value: collection.kind)
                            Text(collection.url).font(.caption).textSelection(.enabled)
                            Text("Provider track fetching is not yet connected.")
                                .foregroundStyle(.secondary)
                        }.navigationTitle(collection.name)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(collection.name).font(.headline)
                            Text("\(collection.kind) · \(collection.source)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: store.removeCollections)
            }.navigationTitle("Playlists & Albums")
        }
    }
}

struct DownloadsScreen: View {
    @ObservedObject private var store = MusicStore.shared
    var body: some View {
        NavigationStack {
            List {
                if store.downloads.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
                }
                ForEach(store.downloads) { download in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(download.title).font(.headline)
                        Text(download.state).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Downloads")
        }
    }
}

struct OfflineScreen: View {
    @ObservedObject private var store = MusicStore.shared
    @State private var selected: String?
    var body: some View {
        NavigationStack {
            List {
                if store.savedFiles.isEmpty {
                    ContentUnavailableView("No offline files", systemImage: "music.note.list")
                }
                ForEach(store.savedFiles, id: \.self) { file in
                    HStack {
                        Text(file).lineLimit(2)
                        Spacer()
                        Button { selected = file } label: { Image(systemName: "play.circle.fill") }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) { store.removeFile(file) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Offline Library")
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
