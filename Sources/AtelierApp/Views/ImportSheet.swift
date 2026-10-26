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
    @State private var eventName = ""
    @State private var keywords = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Photos").font(.title2.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("From").font(.headline)
                ForEach(model.pendingImportSources, id: \.self) { url in
                    Text(url.path).font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }

            Picker("Mode", selection: $copyFiles) {
                Text("Add (reference files where they are)").tag(false)
                Text("Copy to library").tag(true)
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
                    TextField("Event name", text: $eventName, prompt: Text("e.g. Kochi Backwaters"))
                    Text("Files go to YYYY/YYYY-MM-DD \(eventName.isEmpty ? "Event" : eventName)/ and every copy is verified by hash.")
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
    }

    private var options: ImportOptions {
        let mode: ImportMode = copyFiles
            ? .copy(destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true), eventName: eventName)
            : .reference
        return ImportOptions(mode: mode, keywords: keywords.split(separator: ",").map(String.init))
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
