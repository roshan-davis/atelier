import SwiftUI

struct BuiltInReferencePicker: View {
    let selection: BuiltInLookReference?
    let pick: (BuiltInLookReference) -> Void

    private static let inset: CGFloat = 14
    private static let columnSpacing: CGFloat = 10
    private static let columnWidth: CGFloat = 174
    private static let cardInset: CGFloat = 6
    private static let imageWidth = columnWidth - 2 * cardInset
    static let width: CGFloat = {
        let count = CGFloat(BuiltInLookReference.Theme.allCases.count)
        return count * columnWidth + (count - 1) * columnSpacing + 2 * inset
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Built-in References").font(.headline)
            Text("Pick a portrait or a wider scene. Each study matches the whole photo.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ForEach(BuiltInLookReference.Theme.allCases) { theme in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(theme.rawValue).font(.subheadline.weight(.semibold))
                        ForEach(BuiltInLookReference.allCases.filter { $0.theme == theme }) { reference in
                            card(reference)
                        }
                    }
                    .frame(width: Self.columnWidth, alignment: .leading)
                }
            }
        }
        .padding(Self.inset)
        .frame(width: Self.width)
    }

    private func card(_ reference: BuiltInLookReference) -> some View {
        let selected = reference == selection
        return Button { pick(reference) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Color.primary.opacity(0.06)
                    // The studies are drawn 280 × 180.
                    .frame(width: Self.imageWidth, height: Self.imageWidth * 180 / 280)
                    .overlay {
                        if let image = Self.thumbnails[reference] {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFit()
                        }
                    }
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        }
                    }
                Text(reference.scene.rawValue)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reference.palette)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reference.regions)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.imageWidth, alignment: .leading)
            .padding(Self.cardInset)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .cursor(.link)
        .accessibilityLabel(reference.name)
        .accessibilityHint("\(reference.palette) \(reference.regions)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static let thumbnails = Dictionary(uniqueKeysWithValues: BuiltInLookReference.allCases.compactMap { reference in
        reference.image(width: 384).map { (reference, $0) }
    })
}
