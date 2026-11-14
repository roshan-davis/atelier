import AtelierCore
import SwiftUI

/// Search and filters above the photos, and in the grid the thumbnail size slider. When the
/// column is narrow, the filters fold into one Filters menu so the bar never pushes past its
/// column. The Filmstrip's Filter pop-up sets the same rules.
struct FilterBar: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage(GridThumbnails.sizeKey) private var thumbnailSize = GridThumbnails.defaultSize

    private struct SizingKey: Hashable {
        let showsSizeSlider: Bool
        let rating: Int
        let flag: Flag?
        let label: ColorLabel?
        let edited: Bool?
        let notes: NotesFilter?
    }

    var body: some View {
        let key = SizingKey(showsSizeSlider: model.mode == .grid, rating: model.filter.minRating,
                            flag: model.filter.flag, label: model.filter.colorLabel, edited: model.filter.edited,
                            notes: model.filter.notes)
        AdaptiveControlBar(sizingKey: key) {
            HStack(spacing: 14) {
                search.frame(minWidth: 180, idealWidth: 180, maxWidth: 320)
                ratingPicker.fixedSize()
                flagPicker.fixedSize()
                labelPicker.fixedSize()
                editedPicker.fixedSize()
                notesPicker.fixedSize()
                Spacer(minLength: 0)
                sizeSlider
            }
        } compact: {
            HStack(spacing: 10) {
                search.frame(minWidth: 120, idealWidth: 120, maxWidth: 320)
                Menu {
                    ratingPicker
                    flagPicker
                    labelPicker
                    editedPicker
                    notesPicker
                } label: {
                    Label(activeCount == 0 ? "Filters" : "Filters (\(activeCount))",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                Spacer(minLength: 0)
                sizeSlider
            }
        } minimum: {
            search
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var activeCount: Int {
        (model.filter.minRating > 0 ? 1 : 0) + (model.filter.flag != nil ? 1 : 0) + (model.filter.colorLabel != nil ? 1 : 0)
            + (model.filter.edited != nil ? 1 : 0) + (model.filter.notes != nil ? 1 : 0)
    }

    private var search: some View {
        TextField("Search filename, title, caption, keyword, note", text: $model.filter.text)
            .textFieldStyle(.roundedBorder)
    }

    private var ratingPicker: some View {
        Picker("Rating", selection: $model.filter.minRating) {
            Text("Any").tag(0)
            ForEach(1...5, id: \.self) { stars in
                Text(String(repeating: "★", count: stars) + (stars < 5 ? " +" : "")).tag(stars)
            }
        }
    }

    private var flagPicker: some View {
        Picker("Flag", selection: $model.filter.flag) {
            Text("Any").tag(Flag?.none)
            Text("Picked").tag(Flag?.some(.picked))
            Text("Unflagged").tag(Flag?.some(Flag.none))
            Text("Rejected").tag(Flag?.some(.rejected))
        }
    }

    private var editedPicker: some View {
        Picker("Edits", selection: $model.filter.edited) {
            Text("Any").tag(Bool?.none)
            Text("Edited").tag(Bool?.some(true))
            Text("Unedited").tag(Bool?.some(false))
        }
    }

    private var notesPicker: some View {
        Picker("Notes", selection: $model.filter.notes) {
            Text("Any").tag(NotesFilter?.none)
            ForEach(NotesFilter.allCases, id: \.self) { choice in
                Text(choice.title).tag(NotesFilter?.some(choice))
            }
        }
    }

    /// Lightroom's grid toolbar slider: smaller to larger thumbnails. The Filmstrip resizes by
    /// dragging its top edge instead.
    @ViewBuilder private var sizeSlider: some View {
        if model.mode == .grid {
            HStack(spacing: 5) {
                Image(systemName: "minus")
                DevelopSlider(value: $thumbnailSize, range: GridThumbnails.sizeRange, step: 1,
                              origin: GridThumbnails.sizeRange.lowerBound, gradient: nil, name: "Thumbnail size")
                    .frame(width: 90)
                Image(systemName: "plus")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("Thumbnail size")
        }
    }

    private var labelPicker: some View {
        Picker("Label", selection: $model.filter.colorLabel) {
            Text("Any").tag(ColorLabel?.none)
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Text(label.rawValue).tag(ColorLabel?.some(label))
            }
        }
    }
}
