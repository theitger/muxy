import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → Phone: switch the remote on, pair by scanning, lock phones
/// out again.
struct RemoteSettings: View {
    @ObservedObject private var server = RemoteServer.shared
    @State private var enabled = UserDefaults.standard.bool(forKey: RemoteServer.enabledKey)
    @State private var showSecret = false
    @State private var secretVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Phone"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("Use Muxy from your phone on the same Wi-Fi."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, on in server.setEnabled(on) }
            }

            if let problem = server.problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.red)
            }

            if server.isRunning {
                if let url = server.pairingURL {
                    HStack(alignment: .top, spacing: 14) {
                        QRCode(text: url)
                            .id(secretVersion)
                            .frame(width: 132, height: 132)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Scan with the phone's camera."))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textBody)
                            Text(L("The code is the key: whoever scans it can use your terminals. Pair again to lock every phone out."))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(server.phones == 1 ? L("1 phone connected") : L("%d phones connected", server.phones))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(server.phones > 0 ? Theme.green : Theme.textDim)
                            Button(L("Pair Again")) {
                                server.pairAgain()
                                secretVersion += 1
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    Text(L("No network connection."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white))
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
