import AtelierCore
import SwiftUI

struct FilterBar: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        HStack(spacing: 14) {
            TextField("Search filename, title, caption, keyword", text: $model.filter.text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Picker("Rating", selection: $model.filter.minRating) {
                Text("Any").tag(0)
                ForEach(1...5, id: \.self) { stars in
                    Text(String(repeating: "★", count: stars) + " +").tag(stars)
                }
            }
            .fixedSize()

            Picker("Flag", selection: $model.filter.flag) {
                Text("Any").tag(Flag?.none)
                Text("Picked").tag(Flag?.some(.picked))
                Text("Unflagged").tag(Flag?.some(Flag.none))
                Text("Rejected").tag(Flag?.some(.rejected))
            }
            .fixedSize()

            Picker("Label", selection: $model.filter.colorLabel) {
                Text("Any").tag(ColorLabel?.none)
                ForEach(ColorLabel.allCases, id: \.self) { label in
                    Text(label.rawValue).tag(ColorLabel?.some(label))
                }
            }
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
