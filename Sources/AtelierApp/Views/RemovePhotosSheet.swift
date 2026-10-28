import AppKit
import AtelierCore
import SwiftUI

/// Photo > Remove Photo…: Remove (catalog only), or Delete from Disk (files to the Trash), as in
/// Lightroom. A RAW+JPEG pair gets a checkbox per kind of file, all checked to start with.
struct RemovePhotosSheet: View {
    let removal: PhotoRemoval
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<RemovalPlan.FileType>

    init(removal: PhotoRemoval) {
        self.removal = removal
        _checked = State(initialValue: Set(removal.plan.fileTypes))
    }

    private var plan: RemovalPlan { removal.plan }
    private var files: [RemovalPlan.File] { plan.files(of: checked) }
    private var onlineFiles: [RemovalPlan.File] { files.filter { $0.url != nil } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                Text("Remove takes \(removal.photoCount == 1 ? "it" : "them") out of the catalog and leaves the files where they are. Delete from Disk also moves the files to the Trash.")
                    .fixedSize(horizontal: false, vertical: true)
                if plan.fileTypes.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.fileTypes) { type in
                            Toggle(isOn: binding(for: type)) {
                                HStack(spacing: 6) {
                                    Text(type.label)
                                    Text(fileCount(plan.files(of: [type]).count))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.leading, 2)
                }
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes, id: \.self) { Text($0) }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Delete from Disk", role: .destructive) {
                        model.removePhotos(removal, types: checked, fromDisk: true)
                    }
                    .disabled(onlineFiles.isEmpty)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Remove") {
                        model.removePhotos(removal, types: checked, fromDisk: false)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty && plan.virtualCopies.isEmpty)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        if removal.photoCount > 1 { return "Remove \(removal.photoCount) photos?" }
        if let file = plan.files.first { return "Remove “\(file.filename)”?" }
        return "Remove this virtual copy?"
    }

    /// What Delete from Disk will do, in numbers, plus what goes along with it.
    private var notes: [String] {
        var notes: [String] = []
        if !onlineFiles.isEmpty, removal.photoCount > 1 || plan.fileTypes.count > 1 {
            notes.append("Delete from Disk moves \(fileCount(onlineFiles.count)) to the Trash.")
        }
        let offline = files.count - onlineFiles.count
        if offline > 0 {
            notes.append("\(fileCount(offline)) \(offline == 1 ? "is" : "are") on a drive that isn’t connected. Delete from Disk leaves \(offline == 1 ? "it" : "them") in the catalog.")
        }
        let copies = files.reduce(0) { $0 + $1.virtualCopyCount }
        if copies > 0 {
            notes.append("\(copies) virtual cop\(copies == 1 ? "y goes" : "ies go") with \(files.count == 1 ? "it" : "them").")
        }
        if !plan.virtualCopies.isEmpty {
            notes.append("Virtual copies only leave the catalog. The file they share with the original stays.")
        }
        return notes
    }

    private func fileCount(_ count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s")"
    }

    private func binding(for type: RemovalPlan.FileType) -> Binding<Bool> {
        Binding(get: { checked.contains(type) },
                set: { if $0 { checked.insert(type) } else { checked.remove(type) } })
    }
}
