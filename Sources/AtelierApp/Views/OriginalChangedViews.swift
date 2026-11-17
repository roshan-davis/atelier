import AtelierCore
import SwiftUI

/// Develop's banner over the photo when its original changed on its share since import (AT-079c
/// part 3). The photo's preview stays browsable underneath; nothing uses either file until the
/// person chooses. Banner buttons, not commands: they answer this one photo's question, which
/// agents meet as `OriginalChangedError` from the command they ran.
struct OriginalChangedBanner: View {
    @EnvironmentObject private var model: LibraryModel
    let change: OriginalChangedError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(change.filename) changed on \(change.place) since it was imported")
                    .font(.headline)
                Text(change.hasKeptCopy
                     ? "Use the new file, or keep editing the copy kept on this Mac from before. Your edits stay either way."
                     : "Use the new file to keep editing; your edits stay. Atelier won't use it until you choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if change.hasKeptCopy {
                        Button("Use the Kept Copy") { model.useKeptOriginal(change) }
                    }
                    Button("Use the New File") {
                        Task { await model.useNewOriginals([change]) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// One sheet for every photo an Export or Edit In run stopped for, while the others carried on
/// (AT-079c part 3, PRD "When the original changed"): Use the New File, Use the Kept Copy (only for
/// a photo kept with Keep on This Mac) or Skip, then Continue runs the command on those let through.
struct ChangedOriginalsSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @State var review: ChangedOriginalsReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.title).font(.headline)
                    Text("The other photos carried on with the \(review.command). Atelier didn't use either file for these. Choose what each one should use; edits stay either way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List {
                ForEach($review.items) { $item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.change.filename).lineLimit(1).truncationMode(.middle)
                            Text(item.change.hasKeptCopy ? "on \(item.change.place) · kept on this Mac" : "on \(item.change.place)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $item.choice) {
                            Text("Use the New File").tag(ChangedOriginalsReview.Choice.useNewFile)
                            if item.change.hasKeptCopy {
                                Text("Use the Kept Copy").tag(ChangedOriginalsReview.Choice.useKeptCopy)
                            }
                            Text("Skip").tag(ChangedOriginalsReview.Choice.skip)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: min(240, CGFloat(review.items.count) * 40 + 8))
            HStack {
                Spacer()
                Button("Skip All", role: .cancel) { model.changedOriginals = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { model.applyChangedOriginals(review) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
