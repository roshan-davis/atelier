import AppKit
import AtelierHDRCore
import SwiftUI

/// The Presets section at the top of HDR's left panel (Rosh, Nov 12, 2026: "Machinery HDR gives
/// great presets on the left panels with thumbnail previews"): every preset as a thumbnail of
/// this photo with it applied, in groups, as Machinery HDR, Photomatix and HDR Efex Pro show
/// theirs. Click applies (one undo step); resting the pointer previews it on the photo, as
/// Develop's presets preview in the Navigator. Favorites (the star) collect at the top; the
/// user's own presets are saved with + and renamed or deleted from the right-click menu.
struct HDRPresetsSection: View {
    @ObservedObject var hdr: HDRController
    @Binding var isExpanded: Bool
    /// Groups the user closed (all open by default), and the favorite presets' ids.
    @AppStorage("hdr.presetGroupsClosed") private var closedList = ""
    @AppStorage("hdr.favoritePresets") private var favoriteList = ""
    @State private var hoverTask: Task<Void, Never>?
    @State private var naming: HDRPreset?
    @State private var savingNew = false
    @State private var nameText = ""
    @State private var deleting: HDRPreset?

    private struct PresetGroup: Identifiable {
        let name: String
        let presets: [HDRPreset]
        var id: String { name }
    }

    private static let favoritesName = "Favorites"

    private var favorites: Set<UUID> { Set(favoriteList.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }

    private var groups: [PresetGroup] {
        var result: [PresetGroup] = []
        let favored = hdr.presets.filter { favorites.contains($0.id) }
        if !favored.isEmpty { result.append(PresetGroup(name: Self.favoritesName, presets: favored)) }
        let user = hdr.presets.filter { !$0.isBuiltIn }
        if !user.isEmpty { result.append(PresetGroup(name: HDRPreset.userGroup, presets: user)) }
        for name in HDRPreset.builtInGroups {
            result.append(PresetGroup(name: name, presets: hdr.presets.filter { $0.isBuiltIn && $0.group == name }))
        }
        return result
    }

    var body: some View {
        SidebarSection(title: "Presets", isExpanded: $isExpanded) {
            Button {
                nameText = ""
                savingNew = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!hdr.hasPhoto || hdr.busy)
            .help("Save the current HDR look as a preset (Exposure isn't included)")
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    groupView(group)
                }
            }
            .disabled(!hdr.hasPhoto || hdr.busy)
        }
        .onDisappear { hoverTask?.cancel(); hdr.previewPreset(nil) }
        .alert("Save HDR Preset", isPresented: $savingNew) {
            TextField("Name", text: $nameText)
            Button("Save") {
                let name = nameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { hdr.savePreset(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves Method, Range, Tone and Texture. Each photo keeps its own Exposure.")
        }
        .alert("Rename Preset", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Rename") {
                let name = nameText.trimmingCharacters(in: .whitespaces)
                if let preset = naming, !name.isEmpty { hdr.renamePreset(preset, to: name) }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .alert("Delete the preset “\(deleting?.name ?? "")”?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let preset = deleting { hdr.deletePreset(preset) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Photos already saved with it keep their look.")
        }
    }

    private func isOpen(_ group: PresetGroup) -> Binding<Bool> {
        Binding(get: { !closedList.split(separator: ",").contains(Substring(group.name)) }, set: { open in
            var closed = Set(closedList.split(separator: ",").map(String.init))
            if open { closed.remove(group.name) } else { closed.insert(group.name) }
            closedList = closed.sorted().joined(separator: ",")
        })
    }

    private func groupView(_ group: PresetGroup) -> some View {
        let open = isOpen(group)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .frame(width: 10)
                    Text(group.name).font(.callout.weight(.medium))
                    Spacer()
                    Text("\(group.presets.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.wrappedValue {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 8) {
                    ForEach(group.presets) { preset in
                        tile(preset)
                    }
                }
            }
        }
    }

    private var aspect: CGFloat {
        guard let size = hdr.pixelSize, size.height > 0 else { return 1.5 }
        return min(2, max(0.66, size.width / size.height))
    }

    private func tile(_ preset: HDRPreset) -> some View {
        let applied = hdr.hasPhoto && preset.matches(hdr.settings)
        let favorite = favorites.contains(preset.id)
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.black.opacity(0.25)
                    if let image = hdr.presetThumbnails[preset.id] {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else if hdr.hasPhoto {
                        ProgressView().controlSize(.small)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(applied ? Color.accentColor : Color.clear, lineWidth: 2))
                Button {
                    toggleFavorite(preset)
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(favorite ? Color.yellow : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(favorite ? "Remove from Favorites" : "Add to Favorites")
            }
            Text(preset.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(applied ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { hoverTask?.cancel(); hdr.applyPreset(preset) }
        .onHover { hover(preset, $0) }
        .help(preset.name)
        .contextMenu {
            Button("Apply") { hdr.applyPreset(preset) }
            Button(favorite ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(preset) }
            if !preset.isBuiltIn {
                Divider()
                Button("Rename…") { nameText = preset.name; naming = preset }
                Button("Delete…", role: .destructive) { deleting = preset }
            }
        }
    }

    private func toggleFavorite(_ preset: HDRPreset) {
        var ids = favorites
        if ids.contains(preset.id) { ids.remove(preset.id) } else { ids.insert(preset.id) }
        favoriteList = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// A short rest before previewing, so sweeping across the grid doesn't render each preset; a
    /// short grace on leaving, so moving to the next one doesn't flash the photo back (as Develop).
    private func hover(_ preset: HDRPreset, _ inside: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(inside ? 120 : 150))
            guard !Task.isCancelled else { return }
            hdr.previewPreset(inside ? preset : nil)
        }
    }
}
