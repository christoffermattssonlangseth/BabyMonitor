import SwiftUI
import UIKit

struct ParentView: View {
    @StateObject private var station: ParentStation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLog = false
    let onLeave: () -> Void

    init(password: String, name: String, onLeave: @escaping () -> Void) {
        _station = StateObject(wrappedValue: ParentStation(password: password, deviceName: name))
        self.onLeave = onLeave
    }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            controls
        }
        .background(Color.black)
        .onAppear {
            // Keep the screen on while the app is open; lock the phone whenever you like.
            UIApplication.shared.isIdleTimerDisabled = true
            station.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            station.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            station.setAppActive(phase == .active)
        }
        .sheet(isPresented: $showLog) { logSheet }
    }

    // MARK: Video

    private var videoArea: some View {
        ZStack {
            Color.black
            if case .live = station.phase, station.showVideo, station.babyCameraOn, let frame = rotatedFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
                    .padding(24)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                HStack {
                    Pill(text: phaseText, color: phaseColor)
                    Spacer()
                    TimelineView(.everyMinute) { context in
                        Pill(text: context.date.formatted(date: .omitted, time: .shortened))
                    }
                }
                if let banner = station.banner {
                    Button {
                        station.dismissBanner()
                    } label: {
                        Text(banner.text)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(banner.critical ? Color.red : Color.orange, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(banner.critical ? Color.white : Color.black)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding()
            .animation(.default, value: station.banner)
        }
    }

    private var rotatedFrame: UIImage? {
        guard let frame = station.frame else { return nil }
        let turns = ((station.rotation % 4) + 4) % 4
        guard turns != 0, let cgImage = frame.cgImage else { return frame }
        let orientations: [UIImage.Orientation] = [.up, .right, .down, .left]
        return UIImage(cgImage: cgImage, scale: frame.scale, orientation: orientations[turns])
    }

    @ViewBuilder
    private var placeholder: some View {
        switch station.phase {
        case .searching:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for the baby station…\nOpen Baby Monitor on the nursery phone and choose “Baby station”. Both phones must be on the same Wi-Fi.")
            }
        case .connecting(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(name)…")
            }
        case .cannotConnect:
            Text("Found the baby station but can’t connect.\nCheck that both phones use the same family password.")
        case .localNetworkDenied:
            VStack(spacing: 12) {
                Text("Baby Monitor needs Local Network access to find the baby station.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .live:
            if !station.babyCameraOn {
                Label("The baby station’s camera is off. Sound only.", systemImage: "video.slash")
            } else if !station.showVideo {
                Label("Listening (video hidden)", systemImage: "ear")
            } else {
                ProgressView()
            }
        }
    }

    private var phaseText: String {
        switch station.phase {
        case .searching: return "Searching…"
        case .connecting: return "Connecting…"
        case .live(let name): return "Live · \(name)"
        case .cannotConnect: return "Can’t connect"
        case .localNetworkDenied: return "No network access"
        }
    }

    private var phaseColor: Color {
        switch station.phase {
        case .live: return .green
        case .searching, .connecting: return .orange
        case .cannotConnect, .localNetworkDenied: return .red
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LevelMeter(level: station.level, threshold: Int(station.threshold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Alert when sound is above the white line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $station.threshold, in: 5...90, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("…for at least")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("For at least", selection: $station.sustain) {
                    ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                Button {
                    station.muted.toggle()
                } label: {
                    Image(systemName: station.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24)
                }
                .accessibilityLabel(station.muted ? "Unmute" : "Mute")
                Slider(value: $station.volume, in: 0...1)
                    .disabled(station.muted)
            }

            HStack(spacing: 10) {
                Button {
                    station.showVideo.toggle()
                } label: {
                    Image(systemName: station.showVideo ? "eye.slash" : "eye")
                }
                .accessibilityLabel(station.showVideo ? "Hide video" : "Show video")
                Button {
                    station.rotation = (station.rotation + 1) % 4
                } label: {
                    Image(systemName: "rotate.right")
                }
                .accessibilityLabel("Rotate picture")
                Button {
                    showLog = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Activity log")
                Spacer()
                Button("Leave", role: .destructive) {
                    station.stop()
                    onLeave()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(white: 0.1))
    }

    private var logSheet: some View {
        NavigationStack {
            List(station.log) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                }
            }
            .overlay {
                if station.log.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                Button("Done") { showLog = false }
            }
        }
    }
}
