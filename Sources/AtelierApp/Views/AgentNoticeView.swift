import SwiftUI

/// The notice at the bottom of the photo after a chat app changed something (AT-050c), such as
/// "Claude: Rate 3 stars (37 photos)", with Undo while the change can still be undone. It goes
/// away by itself after a few seconds.
struct AgentNoticeView: View {
    @ObservedObject var agents: AgentServer

    var body: some View {
        ZStack {
            if let notice = agents.notice {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(.secondary)
                    Text(notice.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let change = notice.changeID {
                        Button("Undo") { agents.undoFromWindow(change) }
                            .help("Undo this change made by the chat app")
                    }
                    Button {
                        agents.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close")
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .frame(maxWidth: 560)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(notice.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: agents.notice)
    }
}
