import AgentMCP
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Atelier > Settings… > Agents > Phone (AT-050f): let a paired phone (Docent on iPhone) use
/// Atelier over Tailscale, pair one with a QR code, and see, limit or revoke paired phones.
struct PhoneSettingsSection: View {
    @ObservedObject var phone: AgentPhone
    @AppStorage(PhoneSettings.enabledKey) private var enabled = false
    @State private var portText = String(PhoneSettings.port)
    @State private var showsPairing = false

    var body: some View {
        SettingsSection("Phone") {
            Toggle("Let a paired phone use Atelier over Tailscale", isOn: Binding(
                get: { enabled },
                set: { phone.setEnabled($0) }))
            status
            if enabled {
                LabeledContent("Port") {
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .onSubmit(applyPort)
                        .help("Atelier listens here on this Mac's Tailscale address. Easel uses 47802.")
                }
                LabeledContent("Pair a phone") {
                    Button("Pair a Phone…") {
                        phone.startPairing()
                        showsPairing = true
                    }
                    .disabled(phone.pairingURL == nil)
                }
            }
            ForEach(phone.devices) { device in
                PhoneDeviceRow(device: device,
                               setProfile: { phone.setProfile($0, for: device.id) },
                               setAsksForMe: { phone.setAsksForMe($0, for: device.id) },
                               revoke: { phone.revoke(device.id) })
            }
        } footer: {
            Text("A phone on your tailnet (Docent on iPhone) works with the Atelier open on this Mac: the same tools as a chat app here. Atelier listens only on this Mac's Tailscale address, never on Wi-Fi or Ethernet, and each phone has its own key from its pairing code. A paired phone is never asked about on this Mac. With This app asks for me on, the phone's own Allow is the only approval for changes that would ask here; with it off, those changes fail on the phone at once. Revoke stops a phone straight away. The Mac must be awake with Atelier open.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsPairing, onDismiss: { phone.cancelPairing() }) {
            PairingSheet(phone: phone, close: { showsPairing = false })
        }
        .onAppear { phone.reloadDevices() }
    }

    @ViewBuilder private var status: some View {
        switch phone.status {
        case .off:
            EmptyView()
        case .agentsOff:
            Label("Turn on Allow chat apps to use Atelier above first.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        case .noTailscale:
            Label("Turn on Tailscale on this Mac to pair a phone.", systemImage: "network.slash")
                .foregroundStyle(.orange)
                .font(.callout)
        case .listening(let addresses, let port):
            let shown = phone.hostName ?? addresses.dropFirst().joined(separator: ", ")
            Label("Ready for phones at \(shown), port \(String(port)).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .textSelection(.enabled)
        case .failed(let problem):
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            portText = String(PhoneSettings.port)
            return
        }
        phone.setPort(port)
    }
}

/// One paired phone: its name, when it paired and was last used, its profile, This app asks
/// for me, and Revoke.
private struct PhoneDeviceRow: View {
    let device: PairedDevice
    let setProfile: (AgentProfile) -> Void
    let setAsksForMe: (Bool) -> Void
    let revoke: () -> Void

    var body: some View {
        LabeledContent {
            HStack {
                Picker(device.name, selection: Binding(get: { device.profile }, set: { setProfile($0) })) {
                    ForEach(AgentProfile.allCases, id: \.self) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(device.profile.summary)
                Toggle("This app asks for me", isOn: Binding(get: { device.asksForMe }, set: { setAsksForMe($0) }))
                    .toggleStyle(.checkbox)
                    .help("The phone's own Allow is the only approval for changes that would ask on this Mac.")
                Button("Revoke", role: .destructive, action: revoke)
                    .controlSize(.small)
                    .help("Stop \(device.name) from using Atelier now. Pair it again to bring it back.")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .foregroundStyle(.secondary)
                    Text(device.name)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var detail: String {
        var parts = ["Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"]
        if let used = device.lastUsed { parts.append("Last used \(used.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// Pair a Phone…: the QR code, on this Mac's screen only, for 5 minutes with a countdown.
private struct PairingSheet: View {
    @ObservedObject var phone: AgentPhone
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair a Phone")
                .font(.title3.weight(.semibold))
            if let name = phone.justPaired, phone.pairing == nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.green)
                    .frame(width: 220, height: 220)
                Text("\(name) is paired.")
                    .font(.callout)
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            } else if let code = phone.pairing, let payload = phone.pairingPayload(code) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(code.expires.timeIntervalSince(context.date).rounded(.up)))
                    VStack(spacing: 14) {
                        QRCodeImage(text: payload)
                            .frame(width: 220, height: 220)
                            .opacity(left == 0 ? 0.15 : 1)
                        Text("In Docent on your iPhone, choose Settings > Servers > Add > Scan Pairing Code, then point the camera here.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if left > 0 {
                            Text("The code works once and expires in \(left / 60):\(String(format: "%02d", left % 60)).")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("Cancel", action: close)
                                .keyboardShortcut(.cancelAction)
                        } else {
                            Text("This code expired.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Cancel", action: close)
                                    .keyboardShortcut(.cancelAction)
                                Button("New Code") { phone.startPairing() }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                    }
                }
            } else {
                Text("Atelier isn't listening for phones right now.")
                    .font(.callout)
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// A QR code drawn crisp (each module a whole number of points).
private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Pairing code")
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
