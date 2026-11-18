import AppKit
import AtelierCore
import SwiftUI

/// Settings > Storage > + (AT-079a, cloud drive folders AT-079b): one sheet of one size in three
/// steps, as the Import dialog: what kind, which one (starting from what Atelier can find), then the
/// name. Object storage (S3-compatible, for backups) is the fourth kind (AT-079e).
struct AddLocationSheet: View {
    static let size = CGSize(width: 600, height: 440)

    enum Kind: String, CaseIterable, Identifiable {
        case drive, networkShare, cloudFolder, objectStorage
        var id: String { rawValue }
        var storageKind: StorageLocationKind {
            switch self {
            case .drive: return .drive
            case .networkShare: return .networkShare
            case .cloudFolder: return .cloudFolder
            case .objectStorage: return .objectStorage
            }
        }
        var title: String {
            switch self {
            case .drive: return "Drive or Folder on This Mac"
            case .networkShare: return "Network Share (NAS)"
            case .cloudFolder: return "Cloud Drive Folder"
            case .objectStorage: return "Object Storage (S3)"
            }
        }
        var line: String {
            switch self {
            case .drive: return "This Mac, an external drive, or a folder on one."
            case .networkShare: return "A NAS or another Mac sharing over SMB."
            case .cloudFolder: return "iCloud Drive, Dropbox, Google Drive, OneDrive, synced by their Mac app."
            case .objectStorage: return "A bucket on Amazon S3, Backblaze B2, Cloudflare R2, Wasabi or MinIO, for catalog backups."
            }
        }
    }

    enum Step: Int { case kind, place, name }

    /// What step 2 found: the volume and the folder on it.
    struct Place {
        var mounted: MountedVolume
        var folder: URL
    }

    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = ShareBrowser()

    @State private var step: Step
    @State private var kind: Kind
    @State private var place: Place?
    @State private var name: String
    @State private var connectAtLaunch = true
    /// Starts on for network shares and cloud drive folders, off for a drive (set when the kind is known).
    @State private var makesSmartPreviews: Bool?
    @State private var address: String
    @State private var connecting: String?
    @State private var problem: String?
    /// Cloud drive folders found on this Mac, and the one picked in step 2.
    @State private var providers: [MountedVolume] = []
    @State private var provider: MountedVolume?
    /// Object storage: the bucket being set up, and whether Test Connection passed for it.
    @State private var s3 = S3Form()
    @State private var testing = false
    @State private var tested: S3Bucket?
    /// Snapshots show these instead of a live Bonjour search or this Mac's provider folders.
    var previewServers: [ShareBrowser.Server]?
    var previewProviders: [MountedVolume]?
    let added: (StorageLocation) -> Void

    init(step: Step = .kind, kind: Kind = .networkShare, place: Place? = nil, name: String = "",
         address: String = "", previewServers: [ShareBrowser.Server]? = nil,
         previewProviders: [MountedVolume]? = nil, s3: S3Form = S3Form(), added: @escaping (StorageLocation) -> Void) {
        _s3 = State(initialValue: s3)
        _step = State(initialValue: step)
        _kind = State(initialValue: kind)
        _place = State(initialValue: place)
        _name = State(initialValue: name)
        _address = State(initialValue: address)
        self.previewServers = previewServers
        self.previewProviders = previewProviders
        _providers = State(initialValue: previewProviders ?? [])
        _provider = State(initialValue: previewProviders?.first)
        self.added = added
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .kind: kindStep
                case .place:
                    switch kind {
                    case .networkShare: AnyView(shareStep)
                    case .drive: AnyView(driveStep)
                    case .cloudFolder: AnyView(cloudStep)
                    case .objectStorage: AnyView(objectStorageStep)
                    }
                case .name: nameStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onDisappear { browser.stop() }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack {
            Text("Add Location").font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                ForEach([Step.kind, .place, .name], id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel("Step \(step.rawValue + 1) of 3")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .font(.callout)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if step != .kind {
                Button("Back") { goBack() }
            }
            switch step {
            case .kind:
                Button("Continue") { advanceFromKind() }
                    .keyboardShortcut(.defaultAction)
            case .place:
                switch kind {
                case .networkShare:
                    Button("Connect") { connect(address) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(connecting != nil || ServerAddress.normalized(address) == nil)
                case .drive:
                    Button("Choose…") { chooseFolder() }
                        .keyboardShortcut(.defaultAction)
                case .cloudFolder:
                    Button("Choose Folder…") { chooseCloudFolder() }
                        .disabled(provider == nil)
                    Button("Use All of \(provider?.name ?? "It")") { useWholeProvider() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(provider == nil)
                case .objectStorage:
                    Button("Continue") { testBucket(thenContinue: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(testing || !s3.isComplete)
                }
            case .name:
                Button("Add Location") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .objectStorage ? tested == nil : place == nil))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Step 1

    private var kindStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where are the photos you want to add?")
                .font(.headline)
            HStack(spacing: 14) {
                ForEach(Kind.allCases) { k in
                    KindTile(kind: k, isSelected: k == kind)
                        .onClick(perform: { kind = k }, doubleClick: { kind = k; advanceFromKind() })
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Object storage keeps catalog backups; photos stay on drives, shares and cloud drive folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Step 2

    private var shareStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a server on your network")
                .font(.headline)
            let servers = previewServers ?? browser.servers
            List {
                if servers.isEmpty {
                    HStack(spacing: 8) {
                        if browser.isSearching || previewServers != nil { ProgressView().controlSize(.small) }
                        Text("Looking for servers…").foregroundStyle(.secondary)
                    }
                }
                ForEach(servers) { server in
                    HStack(spacing: 10) {
                        StorageKindTile(kind: .networkShare, size: 22)
                        Text(server.name)
                        Spacer()
                        if connecting == server.address { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                    .onClick(perform: { address = server.address }, doubleClick: { address = server.address; connect(server.address) })
                    .listRowBackground(address == server.address ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 150)
            HStack {
                Text("Address")
                TextField("smb://server/share", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connect(address) }
                if connecting != nil { ProgressView().controlSize(.small) }
            }
            Text("macOS asks for the password the first time and keeps it in your Keychain. If you saved it in Finder, nothing is asked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { if previewServers == nil { browser.start() } }
    }

    private var cloudStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a cloud drive")
                .font(.headline)
            List {
                if providers.isEmpty {
                    Text("No cloud drive folders on this Mac. Install iCloud Drive, Dropbox, Google Drive, OneDrive or another provider's Mac app and sign in; its folder shows up here.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(providers, id: \.identityKey) { found in
                    HStack(spacing: 10) {
                        StorageKindTile(kind: .cloudFolder, size: 22)
                        Text(found.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onClick(perform: { provider = found }, doubleClick: { provider = found; useWholeProvider() })
                    .listRowBackground(provider?.identityKey == found.identityKey ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 150)
            Text("Use all of it, or choose the folder where you keep photos. The provider's app keeps the files in sync; Atelier never signs in. A photo that's only in the cloud shows a cloud badge and downloads when you open it in Develop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard previewProviders == nil else { return }
            providers = CloudFolders.providers()
            if provider == nil { provider = providers.first }
        }
    }

    private var objectStorageStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the bucket's details")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("Service").gridColumnAlignment(.trailing)
                    Picker("Service", selection: Binding(get: { s3.service }, set: { s3.choose($0); tested = nil })) {
                        ForEach(S3Form.Service.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }
                GridRow {
                    Text("Region")
                    TextField(s3.service.regionHint, text: Binding(get: { s3.region }, set: { s3.setRegion($0); tested = nil }))
                }
                GridRow {
                    Text("Endpoint")
                    TextField(s3.service.endpointHint, text: Binding(get: { s3.endpoint }, set: { s3.endpoint = $0; s3.endpointEdited = true; tested = nil }))
                }
                GridRow {
                    Text("Bucket")
                    TextField("my-photo-backups", text: Binding(get: { s3.bucket }, set: { s3.bucket = $0; tested = nil }))
                }
                GridRow {
                    Text("Folder")
                    TextField("Optional, for example Atelier", text: Binding(get: { s3.folder }, set: { s3.folder = $0; tested = nil }))
                }
                GridRow {
                    Text("Access Key")
                    TextField("", text: Binding(get: { s3.accessKey }, set: { s3.accessKey = $0; tested = nil }))
                }
                GridRow {
                    Text("Secret Key")
                    SecureField("", text: Binding(get: { s3.secretKey }, set: { s3.secretKey = $0; tested = nil }))
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Test Connection") { testBucket(thenContinue: false) }
                    .disabled(testing || !s3.isComplete)
                if testing { ProgressView().controlSize(.small) }
                if tested != nil, !testing {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
            }
            Text("The keys are kept in your Keychain, never in the catalog or its backups. Use keys that can only reach this bucket.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var driveStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a drive or a folder")
                .font(.headline)
            Text("Pick the whole drive, or only the folder where you keep photos, for example Photos SSD/Portfolio. Photos already in Atelier from that drive stay where they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose…") { chooseFolder() }
        }
    }

    // MARK: Step 3

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kind == .objectStorage, let bucket = tested {
                HStack(spacing: 12) {
                    StorageKindTile(kind: .objectStorage, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bucket.prefix.isEmpty ? bucket.bucket : "\(bucket.bucket)/\(bucket.prefix)").lineLimit(1)
                        Text(bucket.endpoint.host ?? bucket.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let place {
                HStack(spacing: 12) {
                    StorageKindTile(kind: placeKind, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.folder.path).lineLimit(1).truncationMode(.middle)
                        if let server = place.mounted.serverAddress.flatMap(ServerAddress.display) {
                            Text(server).font(.caption).foregroundStyle(.secondary)
                        } else if place.mounted.kind == .cloud {
                            Text("Synced by \(place.mounted.name)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Form {
                TextField("Name", text: $name)
                if placeKind == .networkShare {
                    Toggle("Connect when Atelier opens", isOn: $connectAtLaunch)
                }
                if placeKind != .objectStorage {
                    Toggle("Make smart previews for photos here", isOn: Binding(
                        get: { makesSmartPreviews ?? Catalog.makesSmartPreviewsByDefault(placeKind) },
                        set: { makesSmartPreviews = $0 }))
                        .help("A small copy of each photo you import from here is kept on this Mac, so you can edit it in Develop while this location is offline.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text(kind == .objectStorage
                 ? "Catalog backups go to Atelier Backups in this bucket. Choose when in Settings > Storage > Backups."
                 : "Photos you import from here stay where they are. Atelier keeps its catalog and previews on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the chosen place is, whichever tile led there: a folder picked under "Drive or Folder"
    /// that is in Dropbox is a cloud drive folder, one on a mounted share is a network share.
    private var placeKind: StorageLocationKind {
        place.map { StorageLocationKind($0.mounted.kind) } ?? kind.storageKind
    }

    // MARK: Actions

    private func testBucket(thenContinue: Bool) {
        guard let bucket = s3.bucketValue else {
            problem = "The endpoint isn't a valid address, for example https://s3.eu-west-2.amazonaws.com."
            return
        }
        if thenContinue, tested == bucket { continueWithBucket(bucket); return }
        problem = nil
        testing = true
        let client = S3Client(bucket: bucket, credentials: s3.credentials)
        Task {
            do {
                try await client.testConnection()
                tested = bucket
                if thenContinue { continueWithBucket(bucket) }
            } catch {
                tested = nil
                problem = error.localizedDescription
            }
            testing = false
        }
    }

    private func continueWithBucket(_ bucket: S3Bucket) {
        name = bucket.bucket
        step = .name
    }

    private func advanceFromKind() {
        problem = nil
        step = .place
        if kind == .drive { chooseFolder() }
    }

    private func goBack() {
        problem = nil
        switch step {
        case .name: step = .place
        case .place: step = .kind
        case .kind: break
        }
    }

    private func connect(_ text: String) {
        guard connecting == nil else { return }
        problem = nil
        connecting = text
        NetworkShares.connect(text, allowUI: true) { result in
            connecting = nil
            switch result {
            case .success(let roots):
                guard let root = roots.first, let mounted = try? VolumeIdentity.volume(atRoot: root) else {
                    problem = "Connected, but macOS didn't say where the share is."
                    return
                }
                choose(Place(mounted: mounted, folder: root))
            case .failure(.cancelled):
                break
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    private func useWholeProvider() {
        guard let provider else { return }
        choose(Place(mounted: provider, folder: provider.rootURL))
    }

    /// The Open panel inside the chosen provider's folder; a folder elsewhere isn't a cloud folder.
    private func chooseCloudFolder() {
        guard let provider else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = provider.rootURL
        panel.prompt = "Choose"
        panel.message = "Choose the folder in \(provider.name) where you keep photos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let holder = CloudFolders.provider(containing: url, in: providers) else {
            problem = "That folder isn't in a cloud drive folder. Choose one inside \(provider.name)."
            return
        }
        choose(Place(mounted: holder, folder: url))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a drive or a folder where you keep photos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            choose(Place(mounted: try VolumeIdentity.volume(containing: url), folder: url))
        } catch {
            problem = "Couldn't read that folder: \(error.localizedDescription)"
        }
    }

    private func choose(_ found: Place) {
        place = found
        let root = VolumeIdentity.relativePath(of: found.folder, inVolumeAt: found.mounted.rootURL)
        name = root.isEmpty ? found.mounted.name : (root as NSString).lastPathComponent
        step = .name
    }

    private func add() {
        if kind == .objectStorage {
            guard let bucket = tested else { return }
            do {
                let location = try model.catalog.addObjectStorageLocation(
                    name: name.trimmingCharacters(in: .whitespaces), bucket: bucket, credentials: s3.credentials)
                model.refreshVolumes()
                added(location)
                dismiss()
            } catch {
                problem = "Couldn't add the location: \(error.localizedDescription)"
            }
            return
        }
        guard let place else { return }
        do {
            let location = try model.catalog.addStorageLocation(
                folder: place.folder, on: place.mounted, name: name.trimmingCharacters(in: .whitespaces),
                kind: placeKind, connectAtLaunch: placeKind == .networkShare && connectAtLaunch,
                makesSmartPreviews: placeKind != .objectStorage && (makesSmartPreviews ?? Catalog.makesSmartPreviewsByDefault(placeKind)))
            model.refreshVolumes()
            added(location)
            dismiss()
        } catch {
            problem = "Couldn't add the location: \(error.localizedDescription)"
        }
    }
}

/// A large choice tile in Add Location's first step.
private struct KindTile: View {
    let kind: AddLocationSheet.Kind
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StorageKindTile(kind: kind.storageKind, size: 40)
            Text(kind.title)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(kind.line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        // Grows with its text; the row makes all four as tall as the tallest (four tiles leave
        // the Cloud Drive and Object Storage descriptions too long for a fixed 172 pt).
        .frame(maxWidth: .infinity, minHeight: 172, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Add Location's object storage fields, with the endpoint filled from the service and region.
struct S3Form: Equatable {
    enum Service: String, CaseIterable, Identifiable {
        case amazon, backblaze, cloudflare, wasabi, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .amazon: return "Amazon S3"
            case .backblaze: return "Backblaze B2"
            case .cloudflare: return "Cloudflare R2"
            case .wasabi: return "Wasabi"
            case .other: return "MinIO or Other"
            }
        }
        var defaultRegion: String {
            switch self {
            case .amazon, .wasabi, .other: return "us-east-1"
            case .backblaze: return "us-west-004"
            case .cloudflare: return "auto"
            }
        }
        var regionHint: String { defaultRegion }
        /// The endpoint for a region; nil when it can't be worked out (R2's account id, MinIO).
        func endpoint(region: String) -> String? {
            switch self {
            case .amazon: return "https://s3.\(region).amazonaws.com"
            case .backblaze: return "https://s3.\(region).backblazeb2.com"
            case .wasabi: return "https://s3.\(region).wasabisys.com"
            case .cloudflare, .other: return nil
            }
        }
        var endpointHint: String {
            switch self {
            case .cloudflare: return "https://<account id>.r2.cloudflarestorage.com"
            case .other: return "http://localhost:9000"
            default: return endpoint(region: defaultRegion) ?? ""
            }
        }
        /// AWS wants bucket.endpoint; the others take endpoint/bucket.
        var pathStyle: Bool { self != .amazon }
    }

    var service = Service.amazon
    var region = Service.amazon.defaultRegion
    var endpoint = Service.amazon.endpoint(region: Service.amazon.defaultRegion) ?? ""
    var endpointEdited = false
    var bucket = ""
    var folder = ""
    var accessKey = ""
    var secretKey = ""

    mutating func choose(_ next: Service) {
        service = next
        region = next.defaultRegion
        endpointEdited = false
        endpoint = next.endpoint(region: region) ?? ""
    }

    mutating func setRegion(_ next: String) {
        region = next
        if !endpointEdited, let filled = service.endpoint(region: next.trimmingCharacters(in: .whitespaces)) { endpoint = filled }
    }

    var isComplete: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty && !bucket.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessKey.isEmpty && !secretKey.isEmpty
    }

    var bucketValue: S3Bucket? {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text), url.host?.isEmpty == false else { return nil }
        return S3Bucket(endpoint: url, region: region.trimmingCharacters(in: .whitespaces),
                        bucket: bucket.trimmingCharacters(in: .whitespaces), prefix: folder.trimmingCharacters(in: .whitespaces),
                        pathStyle: service.pathStyle)
    }

    /// Layout snapshots: a filled-in Backblaze bucket (made-up keys).
    static var snapshotSample: S3Form {
        var form = S3Form()
        form.choose(.backblaze)
        form.bucket = "rosh-atelier"
        form.folder = "Mac"
        form.accessKey = "004a1b2c3d4e5f0000000001"
        form.secretKey = "snapshot-secret"
        return form
    }

    var credentials: S3Credentials {
        S3Credentials(accessKey: accessKey.trimmingCharacters(in: .whitespaces), secretKey: secretKey.trimmingCharacters(in: .whitespaces))
    }
}
