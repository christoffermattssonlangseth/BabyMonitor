import AVFoundation
import SwiftUI
import UIKit

struct BabyView: View {
    @StateObject private var station: BabyStation
    @State private var dark = false
    @State private var savedBrightness: CGFloat = 0.5
    let onLeave: () -> Void

    init(password: String, name: String, onLeave: @escaping () -> Void) {
        _station = StateObject(wrappedValue: BabyStation(password: password, name: name))
        self.onLeave = onLeave
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if station.cameraOn {
                CameraPreview(session: station.video.session).ignoresSafeArea()
            } else {
                Label("Camera off: parents hear sound only", systemImage: "video.slash")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                HStack {
                    Pill(text: station.isOnline ? "Online" : "Starting…", color: station.isOnline ? .green : .orange)
                    Spacer()
                    Pill(text: watchingText, color: station.parentNames.isEmpty ? nil : .green)
                }
                if let problem = station.problem {
                    Text(problem)
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
                LevelMeter(level: station.level)
                HStack(spacing: 10) {
                    Button {
                        station.cameraOn.toggle()
                    } label: {
                        Image(systemName: station.cameraOn ? "video.fill" : "video.slash.fill")
                    }
                    .accessibilityLabel(station.cameraOn ? "Turn camera off" : "Turn camera on")
                    Button {
                        station.switchCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                    }
                    .accessibilityLabel("Switch camera")
                    .disabled(!station.cameraOn)
                    Button {
                        setDark(true)
                    } label: {
                        Label("Dark screen", systemImage: "moon.fill")
                    }
                    Spacer()
                    Button("Leave", role: .destructive) {
                        station.stop()
                        onLeave()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding()

            if dark {
                Color.black
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("Tap to wake the screen")
                            .font(.footnote)
                            .foregroundStyle(Color(white: 0.15))
                            .padding(.bottom, 40)
                    }
                    .onTapGesture { setDark(false) }
            }
        }
        .statusBarHidden(dark)
        .persistentSystemOverlays(dark ? .hidden : .automatic)
        .onAppear {
            // Keep the screen (and with it the camera) on all night.
            UIApplication.shared.isIdleTimerDisabled = true
            station.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            setDark(false)
            station.stop()
        }
    }

    private var watchingText: String {
        switch station.parentNames.count {
        case 0: return "No parents connected"
        case 1: return "\(station.parentNames[0]) is watching"
        default: return "\(station.parentNames.count) parents watching"
        }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func setDark(_ on: Bool) {
        guard on != dark else { return }
        dark = on
        if on {
            savedBrightness = screen?.brightness ?? 0.5
            screen?.brightness = 0
        } else {
            screen?.brightness = savedBrightness
        }
    }
}

/// Live camera preview on the baby station itself.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
