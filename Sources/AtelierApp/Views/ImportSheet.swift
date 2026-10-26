import AppKit
import AtelierCore
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("import.copy") private var copyFiles = false
    @AppStorage("import.destination") private var destinationPath = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Atelier Library").path
    /// nil means a new import entry.
    @State private var existingGroup: Int64?
    @State private var name = ""
    @State private var keywords = ""

    private var suggestedName: String {
        model.pendingImportSources.first?.lastPathComponent ?? "Import"
    }

    /// The entry name, which also names the event folder in copy mode.
    private var effectiveName: String {
        if let existingGroup, let entry = model.sidebar.imports.first(where: { $0.id == existingGroup }) {
            return entry.name
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Photos").font(.title2.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("From").font(.headline)
                ForEach(model.pendingImportSources, id: \.self) { url in
                    Text(url.path).font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }

            Form {
                Picker("Import into", selection: $existingGroup) {
                    Text("New import").tag(Int64?.none)
                    if !model.sidebar.imports.isEmpty {
                        Divider()
                        ForEach(model.sidebar.imports) { entry in
                            Text("\(entry.name) (\(entry.photoCount))").tag(Int64?.some(entry.id))
                        }
                    }
                }
                if existingGroup == nil {
                    TextField("Name", text: $name, prompt: Text(suggestedName))
                }
            }

            Picker("Files", selection: $copyFiles) {
                Text("Add (leave files where they are)").tag(false)
                Text("Copy to library folder").tag(true)
            }
            .pickerStyle(.radioGroup)

            if copyFiles {
                Form {
                    LabeledContent("Library folder") {
                        HStack {
                            Text(destinationPath).lineLimit(1).truncationMode(.middle)
                            Button("Choose…", action: chooseDestination)
                        }
                    }
                    Text("Files go to YYYY/YYYY-MM-DD \(effectiveName)/ and every copy is verified by hash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Keywords for all photos (comma separated)", text: $keywords)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    model.runImport(options: options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { existingGroup = model.pendingImportGroup }
    }

    private var options: ImportOptions {
        let mode: ImportMode = copyFiles
            ? .copy(destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true), eventName: effectiveName)
            : .reference
        let target: ImportTarget = existingGroup.map { .existingGroup($0) } ?? .newGroup(name: effectiveName)
        return ImportOptions(mode: mode, target: target, keywords: keywords.split(separator: ",").map(String.init))
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }
}
