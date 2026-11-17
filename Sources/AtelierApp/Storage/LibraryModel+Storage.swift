import AppKit
import AtelierCore
import Foundation

/// Storage locations (AT-079a): connecting shares, Show in Finder, and the Storage pane.
extension LibraryModel {
    /// The location shown for a volume in the sidebar: the one rooted at the volume's root.
    func rootLocation(for volume: Volume) -> StorageLocationInfo? {
        sidebar.locations.first { $0.location.volumeId == volume.id && $0.location.rootPath.isEmpty }
    }

    func location(_ id: Int64) -> StorageLocationInfo? {
        sidebar.locations.first { $0.id == id }
    }

    /// A share that isn't mounted and has an address can be connected.
    func canConnect(_ id: Int64) -> Bool {
        guard let info = location(id) else { return false }
        return info.location.serverAddress != nil && info.status != .connected
    }

    func canDisconnect(_ id: Int64) -> Bool {
        guard let info = location(id) else { return false }
        return info.location.kind == .networkShare && info.status == .connected
    }

    /// Connect: mounts the share; macOS asks for the password only if the Keychain has none.
    func connectLocation(_ id: Int64, allowUI: Bool = true) {
        guard let info = location(id), let address = info.location.serverAddress else { return }
        status = "Connecting to \(info.location.name)…"
        NetworkShares.connect(address, allowUI: allowUI) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status = "\(info.location.name) connected"
                self.refreshVolumes()
            case .failure(.cancelled):
                self.status = nil
            case .failure(let error):
                self.status = error.localizedDescription
            }
        }
    }

    func disconnectLocation(_ id: Int64) {
        guard let info = location(id), let volume = info.volume, volume.isOnline, let mount = volume.mountPath else { return }
        status = "Disconnecting \(info.location.name)…"
        NetworkShares.disconnect(URL(fileURLWithPath: mount, isDirectory: true)) { [weak self] error in
            guard let self else { return }
            self.status = error.map { "Couldn't disconnect \(info.location.name): \($0.localizedDescription)" }
            self.refreshVolumes()
        }
    }

    func showLocationInFinder(_ id: Int64) {
        guard let url = location(id)?.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// "Connect when Atelier opens": silent, with the Keychain's password. A share that can't be
    /// reached just stays offline; the status bar says so.
    func connectLocationsAtLaunch() {
        let pending = (try? catalog.storageLocations()) ?? []
        for info in pending where info.location.connectAtLaunch && info.status != .connected {
            guard let address = info.location.serverAddress else { continue }
            NetworkShares.connect(address, allowUI: false) { [weak self] result in
                guard let self else { return }
                if case .failure = result {
                    self.status = "\(info.location.name) is offline. Right-click it under Locations to connect."
                } else {
                    self.refreshVolumes()
                }
            }
        }
    }

}

extension SidebarLocation {
    /// What selecting the sidebar row shows: the whole volume, or the location's own folder.
    /// Nil while there is nothing to show (never connected, or nothing imported from that folder).
    var sidebarItem: SidebarItem? {
        guard let volumeId = info.location.volumeId else { return nil }
        if info.location.rootPath.isEmpty { return .volume(volumeId) }
        return rootFolder?.id.map(SidebarItem.folder)
    }
}
