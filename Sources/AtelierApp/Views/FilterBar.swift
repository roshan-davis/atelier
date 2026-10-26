import AtelierCore
import SwiftUI

/// Search and filters above the photos. When the column is narrow, the three filters fold into
/// one Filters menu so the bar never pushes past its column.
struct FilterBar: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                search.frame(minWidth: 180, maxWidth: 320)
                ratingPicker.fixedSize()
                flagPicker.fixedSize()
                labelPicker.fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                search.frame(minWidth: 120, maxWidth: 320)
                Menu {
                    ratingPicker
                    flagPicker
                    labelPicker
                } label: {
                    Label(activeCount == 0 ? "Filters" : "Filters (\(activeCount))",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            search
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var activeCount: Int {
        (model.filter.minRating > 0 ? 1 : 0) + (model.filter.flag != nil ? 1 : 0) + (model.filter.colorLabel != nil ? 1 : 0)
    }

    private var search: some View {
        TextField("Search filename, title, caption, keyword", text: $model.filter.text)
            .textFieldStyle(.roundedBorder)
    }

    private var ratingPicker: some View {
        Picker("Rating", selection: $model.filter.minRating) {
            Text("Any").tag(0)
            ForEach(1...5, id: \.self) { stars in
                Text(String(repeating: "★", count: stars) + " +").tag(stars)
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

    private var labelPicker: some View {
        Picker("Label", selection: $model.filter.colorLabel) {
            Text("Any").tag(ColorLabel?.none)
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Text(label.rawValue).tag(ColorLabel?.some(label))
            }
        }
    }
}
