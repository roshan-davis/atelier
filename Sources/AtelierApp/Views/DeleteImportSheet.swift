import AppKit
import AtelierCore
import SwiftUI

/// Delete Import…: removes the entry and keeps its photos, unless "Also delete the photos'
/// files" is ticked. That box always starts off, and ticking it shows what will be deleted.
struct DeleteImportSheet: View {
    let deletion: ImportDeletion
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var alsoFiles = false

    private var plan: RemovalPlan { deletion.plan }
    private var online: Int { plan.files.filter { $0.url != nil }.count }
    private var offline: Int { plan.files.count - online }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete the import “\(deletion.name)”?")
                    .font(.headline)
                Text("The import is removed from the sidebar. Its \(photos(deletion.photoCount)) stay in your catalog, under All Photographs and their folders, and on disk.")
                    .fixedSize(horizontal: false, vertical: true)
                if online > 0 {
                    Toggle("Also delete the photos and move their files to the Trash", isOn: $alsoFiles)
                        .toggleStyle(.checkbox)
                }
                if alsoFiles {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(files(online)) will be moved to the Trash.")
                                .fontWeight(.semibold)
                            Text(warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35)))
                }
                HStack {
                    Spacer()
                    if alsoFiles {
                        // Cancel is the default while files would be deleted.
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                        Button("Delete Import and Files", role: .destructive) {
                            model.deleteImport(deletion, files: true)
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Delete Import", role: .destructive) {
                            model.deleteImport(deletion, files: false)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    /// What else goes with the files.
    private var warning: String {
        var parts = ["The photos also leave your catalog with their edits, ratings and keywords, including from any other import or collection they are in. Files in the Trash can be put back until it is emptied."]
        if offline > 0 {
            parts.append("\(files(offline)) on a drive that isn’t connected stay, with their photos.")
        }
        parts.append("Files on a network share with no Trash, such as the NAS, are only deleted after another warning.")
        return parts.joined(separator: " ")
    }

    private func photos(_ count: Int) -> String { "\(count) photo\(count == 1 ? "" : "s")" }
    private func files(_ count: Int) -> String { "\(count) file\(count == 1 ? "" : "s")" }
}
