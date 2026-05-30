import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var rtspServer = RTSPServer()
    @State private var rtspURL: String = "Starting..."
    @State private var isStreaming = false
    @State private var showCopied = false
    @State private var previewLayer: AVCaptureVideoPreviewLayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Camera preview (fills most of screen)
                CameraPreviewView(layer: $previewLayer)
                    .ignoresSafeArea(edges: .top)
                    .overlay(alignment: .topLeading) {
                        statsOverlay
                    }

                // Bottom control panel
                bottomPanel
            }
        }
        .onAppear { setup() }
        .onDisappear { teardown() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Stats Overlay
    var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isStreaming ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .fill(isStreaming ? Color.red : Color.clear)
                            .frame(width: 10, height: 10)
                            .opacity(0.5)
                            .scaleEffect(isStreaming ? 1.8 : 1)
                            .animation(.easeInOut(duration: 0.8).repeatForever(), value: isStreaming)
                    )
                Text(isStreaming ? "LIVE" : "IDLE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(isStreaming ? .red : .gray)
            }

            Text(String(format: "%.0f fps", camera.fps))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            Text(String(format: "%.1f Mbps", camera.bitrateMbps))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            Text(camera.resolution)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(12)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 60)
        .padding(.leading, 16)
    }

    // MARK: - Bottom Panel
    var bottomPanel: some View {
        VStack(spacing: 16) {
            // RTSP URL box
            VStack(alignment: .leading, spacing: 6) {
                Text("RTSP STREAM URL")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gray)

                HStack {
                    Text(rtspURL)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = rtspURL
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopied = false
                        }
                    } label: {
                        Text(showCopied ? "✓" : "COPY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(showCopied ? Color.green : Color.white.opacity(0.15))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Connection hint
            Text("Connect with: ffplay \"\(rtspURL)\" or VLC → Open Network")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            // Start/Stop button
            Button {
                toggleStreaming()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isStreaming ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                    Text(isStreaming ? "STOP STREAM" : "START STREAM")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isStreaming ? Color.red : Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(Color(white: 0.07))
    }

    // MARK: - Logic
    private func setup() {
        // Wire camera → server
        camera.onNAL = { [weak rtspServer] data, pts, isKeyframe in
            rtspServer?.sendNAL(data, pts: pts, isKeyframe: isKeyframe)
        }
        camera.onSPSPPS = { [weak rtspServer] sps, pps in
            // Update all connected clients with SPS/PPS
            // (handled inside RTSPServer via the SDP on DESCRIBE)
        }
        camera.onPreviewLayer = { layer in
            DispatchQueue.main.async {
                previewLayer = layer
            }
        }

        // Start server
        do {
            try rtspServer.start()
        } catch {
            rtspURL = "Server error: \(error)"
            return
        }

        updateURL()

        // Auto-start camera
        toggleStreaming()

        // Refresh IP every 3 seconds (WiFi can change)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            updateURL()
        }
    }

    private func teardown() {
        camera.stop()
        rtspServer.stop()
    }

    private func toggleStreaming() {
        if isStreaming {
            camera.stop()
            isStreaming = false
        } else {
            camera.start()
            isStreaming = true
        }
    }

    private func updateURL() {
        let ip = NetworkUtils.localIPAddress() ?? "not-connected"
        rtspURL = "rtsp://\(ip):8554/live"
    }
}

// MARK: - Camera Preview UIViewRepresentable
struct CameraPreviewView: UIViewRepresentable {
    @Binding var layer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView()
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if let layer {
            uiView.setPreviewLayer(layer)
        }
    }
}

final class PreviewUIView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer?.removeFromSuperlayer()
        layer.frame = bounds
        layer.videoGravity = .resizeAspectFill
        self.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

#Preview {
    ContentView()
}
