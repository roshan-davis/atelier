import AppKit
import AtelierActions
import AtelierCore
import SwiftUI

/// Icons and tints for location kinds, shared by Settings > Storage, Add Location and the sidebar.
enum StorageIcons {
    static func symbol(for kind: StorageLocationKind) -> String {
        switch kind {
        case .drive: return "externaldrive"
        case .networkShare: return "server.rack"
        case .cloudFolder: return "icloud"
        case .objectStorage: return "shippingbox"
        }
    }

    static func tint(for kind: StorageLocationKind) -> Color {
        switch kind {
        case .drive: return SettingsPalette.slate
        case .networkShare: return SettingsPalette.sky
        case .cloudFolder: return SettingsPalette.mist
        case .objectStorage: return SettingsPalette.amber
        }
    }

    /// The status dot in Settings > Storage and the sidebar.
    static func dotColor(for status: StorageLocationStatus) -> Color {
        switch status {
        case .connected: return .green
        case .offline: return Color.secondary.opacity(0.5)
        case .notConnectedYet: return .orange
        }
    }
}

/// A white symbol on the kind's pastel tile, as the Settings sidebar draws its panes.
struct StorageKindTile: View {
    let kind: StorageLocationKind
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(StorageIcons.tint(for: kind))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: StorageIcons.symbol(for: kind))
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Settings > Storage (AT-079a): the places photos are kept, added by the user. Laid out like
/// System Settings > Internet Accounts: a list, + and −, the chosen location's details below.
/// Backups and the cache of remote originals join this pane in AT-079c and AT-079e.
struct StorageSettings: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var selection: Int64?
    @State private var adding = false
    @State private var removing: StorageLocationInfo?
    @State private var freeSpace: [Int64: FreeSpace] = [:]

    private var locations: [StorageLocationInfo] { model.sidebar.locations }
    private var selected: StorageLocationInfo? { locations.first { $0.id == selection } }

    var body: some View {
        Form {
            SettingsSection("Locations", id: "storage.locations") {
                if locations.isEmpty {
                    Text("Add a NAS, a drive or a folder to keep photos there. Nothing is set up until you add it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(locations) { info in
                        StorageLocationRow(info: info, free: freeSpace[info.id], isSelected: info.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = info.id }
                    }
                }
                HStack(spacing: 6) {
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                        .help("Add Location…")
                    Button { removing = selected } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                        .disabled(selected == nil)
                        .help("Remove Location…")
                    Spacer()
                    if locations.isEmpty {
                        Button("Add Location…") { adding = true }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } footer: {
                Text("Atelier keeps its catalog and previews on this Mac. Photos on a location you remove stay in the catalog, offline, and nothing on the location is touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let selected {
                StorageLocationDetail(info: selected) { removing = selected }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) {
            AddLocationSheet { added in
                if let id = added.id { selection = id }
            }
            .environmentObject(model)
        }
        .confirmationDialog(removing.map { "Remove “\($0.location.name)” from Atelier?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Location", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            if let removing {
                Text(removing.photoCount == 0 ? "Nothing on it is changed."
                     : "Its \(removing.photoCount) photos stay in the catalog. Nothing on it is changed.")
            }
        }
        .task(id: locations.map { "\($0.id)-\($0.status.word)" }) { await loadFreeSpace() }
        .onAppear { if selection == nil { selection = locations.first?.id } }
    }

    private func remove() {
        guard let id = removing?.location.id else { return }
        do {
            try model.catalog.removeStorageLocation(id)
            DeleteFeedback.play(.remove)
            if selection == id { selection = nil }
        } catch {
            model.status = "Couldn't remove the location: \(error.localizedDescription)"
        }
        removing = nil
    }

    /// Free space for connected locations, read off the main thread (a share can be slow).
    private func loadFreeSpace() async {
        let roots = locations.compactMap { info in info.rootURL.map { (info.id, $0) } }
        let found = await Task.detached(priority: .utility) { () -> [Int64: FreeSpace] in
            var result: [Int64: FreeSpace] = [:]
            for (id, url) in roots { result[id] = FreeSpace(url) }
            return result
        }.value
        freeSpace = found
    }
}

/// A volume's capacity and free space, for the bar under a location.
struct FreeSpace: Equatable, Sendable {
    var total: Int64
    var available: Int64

    init?(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                             .volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        self.total = Int64(total)
        self.available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
    }

    init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    var usedFraction: Double { total > 0 ? Double(total - available) / Double(total) : 0 }
    var label: String {
        ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " free of "
            + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

/// One location: tile, bold name, grey second line, status dot and word, photo count, free space.
struct StorageLocationRow: View {
    let info: StorageLocationInfo
    let free: FreeSpace?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StorageKindTile(kind: info.location.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.location.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(info.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let free {
                    ProgressView(value: free.usedFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(maxWidth: 180)
                        .help(free.label)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(StorageIcons.dotColor(for: info.status)).frame(width: 7, height: 7)
                    Text(info.statusWord).font(.callout)
                }
                .fixedSize()
                Text(info.photoCount == 1 ? "1 photo" : "\(info.photoCount.formatted()) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The chosen location's settings below the list.
private struct StorageLocationDetail: View {
    @EnvironmentObject private var model: LibraryModel
    let info: StorageLocationInfo
    let remove: () -> Void
    @State private var name = ""

    var body: some View {
        SettingsSection(info.location.name, id: "storage.detail") {
            TextField("Name", text: $name)
                .onSubmit(saveName)
                .onChange(of: info.id) { _, _ in name = info.location.name }
            LabeledContent("Where") {
                Text(info.rootURL?.path ?? info.detailLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(info.rootURL?.path ?? info.detailLine)
            }
            LabeledContent("Photos", value: info.photoCount.formatted())
            if info.location.kind == .networkShare {
                Toggle("Connect when Atelier opens", isOn: Binding(
                    get: { info.location.connectAtLaunch },
                    set: { on in save { $0.connectAtLaunch = on } }))
                LabeledContent("Password") {
                    Text("Kept by macOS in your Keychain")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                let parameters = LocationParameters(location: info.id)
                if info.location.serverAddress != nil {
                    if info.status == .connected {
                        model.actions.button(AtelierAction.disconnectLocation, parameters)
                            .disabled(!model.canDisconnect(info.id))
                    } else {
                        model.actions.button(AtelierAction.connectLocation, parameters)
                    }
                }
                model.actions.button(AtelierAction.showLocationInFinder, parameters)
                    .disabled(info.status != .connected)
                Spacer()
                Button("Remove Location…", role: .destructive, action: remove)
            }
        }
        .onAppear { name = info.location.name }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != info.location.name else { name = info.location.name; return }
        save { $0.name = trimmed }
    }

    private func save(_ change: (inout StorageLocation) -> Void) {
        var location = info.location
        change(&location)
        do { try model.catalog.updateStorageLocation(location) } catch {
            model.status = "Couldn't save the location: \(error.localizedDescription)"
        }
    }
}
