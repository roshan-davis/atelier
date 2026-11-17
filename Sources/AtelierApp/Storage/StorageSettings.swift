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
            if let originals = model.originals {
                OriginalCacheSection(cache: originals)
            }
            if let store = model.smartPreviews {
                SmartPreviewsSection(store: store)
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
    @State private var makesSmartPreviews = false

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
            if info.location.kind != .objectStorage {
                Toggle("Make smart previews for photos here", isOn: Binding(
                    get: { makesSmartPreviews },
                    set: { on in
                        makesSmartPreviews = on
                        try? model.catalog.setMakesSmartPreviews(info.id, on)
                    }))
                    .help("Photos imported from here get a small copy on this Mac, so they can be edited in Develop while it's offline. Library › Previews › Build Smart Previews makes them for photos already here.")
                    .onAppear { makesSmartPreviews = (try? model.catalog.makesSmartPreviews(info.id)) ?? false }
                    .onChange(of: info.id) { _, id in makesSmartPreviews = (try? model.catalog.makesSmartPreviews(id)) ?? false }
            }
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

/// Settings > Storage > Cache (AT-079c): the copies of originals on network shares kept on this Mac.
private struct OriginalCacheSection: View {
    @EnvironmentObject private var model: LibraryModel
    let cache: OriginalCache
    @State private var limit: Int64 = OriginalCache.defaultLimit
    @State private var usage: OriginalCache.Usage?

    private static let sizes: [Int64] = [5, 10, 20, 50, 100, 200].map { $0 * 1_000_000_000 }

    var body: some View {
        SettingsSection("Cache of Originals", id: "storage.cache") {
            Picker("Cache size", selection: $limit) {
                ForEach(Self.sizes, id: \.self) { size in
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).tag(size)
                }
            }
            .onChange(of: limit) { _, size in
                UserDefaults.standard.set(size, forKey: LibraryModel.originalCacheLimitKey)
                Task.detached { cache.limitBytes = size }
                Task { await loadUsage() }
            }
            LabeledContent("In use") {
                Text(usageLine).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Clear Cache…") { askToClear() }
                    .disabled((usage?.cachedCount ?? 0) == 0 && (usage?.keptCount ?? 0) == 0)
            }
        } footer: {
            Text("Photos on a network share are read once into this Mac's Caches folder and opened from there, so editing never waits on the network. The oldest-opened copies go first; the cache never takes more than a quarter of the free space. Photos kept with Keep on This Mac (right-click a folder, import or collection) stay until you choose Free Up Space and don't count toward the size.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            limit = cache.limitBytes
            await loadUsage()
        }
    }

    private var usageLine: String {
        guard let usage else { return "…" }
        if usage.cachedCount == 0 && usage.keptCount == 0 { return "Empty" }
        var line = ByteCountFormatter.string(fromByteCount: usage.cachedBytes, countStyle: .file)
            + (usage.cachedCount == 1 ? " · 1 photo" : " · \(usage.cachedCount.formatted()) photos")
        if usage.keptCount > 0 {
            line += ", plus " + ByteCountFormatter.string(fromByteCount: usage.keptBytes, countStyle: .file) + " kept"
        }
        return line
    }

    private func loadUsage() async {
        usage = await Task.detached(priority: .utility) { try? cache.usage() }.value
    }

    /// Clear Cache…: an alert with "Also remove kept photos (N GB)", unticked when it opens (PRD).
    /// An NSAlert, because its checkbox (the suppression button) is the Mac's own place for one.
    private func askToClear() {
        let alert = NSAlert()
        alert.messageText = "Clear the cache of originals?"
        alert.informativeText = "The originals stay where they are; Atelier reads them again when you open them."
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if let usage, usage.keptCount > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Also remove kept photos ("
                + ByteCountFormatter.string(fromByteCount: usage.keptBytes, countStyle: .file) + ")"
            alert.suppressionButton?.state = .off
        }
        let answer = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            clear(includingKept: alert.suppressionButton?.state == .on)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    private func clear(includingKept: Bool) {
        let open = model.mode == .develop ? model.develop.assetID.flatMap { try? model.catalog.originalID(for: $0) } : nil
        if includingKept { model.cancelKeep() }
        Task {
            let cleared = await Task.detached(priority: .userInitiated) {
                (try? cache.clear(includingKept: includingKept, sparing: open)) != nil
            }.value
            if cleared { DeleteFeedback.play(.remove) }
            await loadUsage()
        }
    }
}

/// Settings > Storage > Smart Previews (AT-079d): how many there are, their size, Discard All.
private struct SmartPreviewsSection: View {
    @EnvironmentObject private var model: LibraryModel
    let store: SmartPreviewStore
    @State private var usage: SmartPreviewStore.Usage?
    @State private var confirming = false

    var body: some View {
        SettingsSection("Smart Previews", id: "storage.smart") {
            LabeledContent("In use") {
                Text(usageLine).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Discard All…") { confirming = true }
                    .disabled((usage?.count ?? 0) == 0)
            }
        } footer: {
            Text("A smart preview is a small editable copy of a photo, about 1 MB, kept on this Mac so you can edit in Develop while the original is offline. Photos in a location with “Make smart previews for photos here” get one when they are imported; for others choose Library > Previews > Build Smart Previews. Your edits apply to the original when it is back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Discard all smart previews?", isPresented: $confirming) {
            Button("Discard All", role: .destructive) { discardAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The originals and your edits are unchanged. Photos whose original is offline can't be edited in Develop until it is back or you build their smart previews again.")
        }
        .task(id: model.smartPreviewProgress == nil) { await loadUsage() }
    }

    private var usageLine: String {
        guard let usage else { return "…" }
        if usage.count == 0 { return "None" }
        return ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
            + (usage.count == 1 ? " · 1 photo" : " · \(usage.count.formatted()) photos")
    }

    private func loadUsage() async {
        let store = self.store
        usage = await Task.detached(priority: .utility) { store.usage() }.value
    }

    private func discardAll() {
        Task {
            _ = await model.discardAllSmartPreviews()
            await loadUsage()
        }
    }
}
