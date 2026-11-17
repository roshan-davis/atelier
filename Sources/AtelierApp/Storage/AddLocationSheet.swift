import AppKit
import AtelierCore
import SwiftUI

/// Settings > Storage > + (AT-079a): one sheet of one size in three steps, as the Import dialog:
/// what kind, which one (starting from what Atelier can find), then the name. Cloud drive folders
/// and object storage join the first step with AT-079b and AT-079e.
struct AddLocationSheet: View {
    static let size = CGSize(width: 600, height: 440)

    enum Kind: String, CaseIterable, Identifiable {
        case drive, networkShare
        var id: String { rawValue }
        var storageKind: StorageLocationKind { self == .drive ? .drive : .networkShare }
        var title: String { self == .drive ? "Drive or Folder on This Mac" : "Network Share (NAS)" }
        var line: String {
            self == .drive ? "This Mac, an external drive, or a folder on one."
                : "A NAS or another Mac sharing over SMB."
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
    @State private var address: String
    @State private var connecting: String?
    @State private var problem: String?
    /// Snapshots show these instead of a live Bonjour search.
    var previewServers: [ShareBrowser.Server]?
    let added: (StorageLocation) -> Void

    init(step: Step = .kind, kind: Kind = .networkShare, place: Place? = nil, name: String = "",
         address: String = "", previewServers: [ShareBrowser.Server]? = nil,
         added: @escaping (StorageLocation) -> Void) {
        _step = State(initialValue: step)
        _kind = State(initialValue: kind)
        _place = State(initialValue: place)
        _name = State(initialValue: name)
        _address = State(initialValue: address)
        self.previewServers = previewServers
        self.added = added
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .kind: kindStep
                case .place: kind == .networkShare ? AnyView(shareStep) : AnyView(driveStep)
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
                if kind == .networkShare {
                    Button("Connect") { connect(address) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(connecting != nil || ServerAddress.normalized(address) == nil)
                } else {
                    Button("Choose…") { chooseFolder() }
                        .keyboardShortcut(.defaultAction)
                }
            case .name:
                Button("Add Location") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || place == nil)
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
            Text("Cloud drive folders (iCloud Drive, Dropbox, Google Drive, OneDrive) and S3 backups come in the next updates.")
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
            if let place {
                HStack(spacing: 12) {
                    StorageKindTile(kind: kind.storageKind, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.folder.path).lineLimit(1).truncationMode(.middle)
                        if let server = place.mounted.serverAddress.flatMap(ServerAddress.display) {
                            Text(server).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Form {
                TextField("Name", text: $name)
                if kind == .networkShare {
                    Toggle("Connect when Atelier opens", isOn: $connectAtLaunch)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Photos you import from here stay where they are. Atelier keeps its catalog and previews on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

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
        guard let place else { return }
        do {
            let location = try model.catalog.addStorageLocation(
                folder: place.folder, on: place.mounted, name: name.trimmingCharacters(in: .whitespaces),
                kind: kind.storageKind, connectAtLaunch: kind == .networkShare && connectAtLaunch)
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
            Text(kind.title).font(.body.weight(.semibold))
            Text(kind.line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 260, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
