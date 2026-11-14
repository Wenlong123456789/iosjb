import Darwin
import SwiftUI
import UIKit

final class LogSink: ObservableObject {
    static let shared = LogSink()

    @Published private(set) var text = ""

    private init() {
        text = "IOSJB \(String(cString: iosjb_version()))\n"
    }

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.count > 120_000 {
            text = String(text.suffix(80_000))
        }
        text += trimmed + "\n"
    }
}

@_cdecl("iosjb_swift_log")
public func iosjbSwiftLog(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let line = String(cString: message)
    DispatchQueue.main.async {
        LogSink.shared.append(line)
    }
}

private func machineIdentifier() -> String {
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
        return "unknown"
    }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
        return "unknown"
    }
    return String(cString: value)
}

private func iosVersion() -> OperatingSystemVersion {
    ProcessInfo.processInfo.operatingSystemVersion
}

private func vulnerabilityWindow() -> Bool {
    let version = iosVersion()
    return version.majorVersion == 27 && version.minorVersion < 2
}

struct ContentView: View {
    @ObservedObject private var sink = LogSink.shared

    @State private var mode = 0
    @State private var iterations = 500.0
    @State private var senders = 6.0
    @State private var sprayCount = 48.0
    @State private var closeDelay = 100.0
    @State private var running = false

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    warningCard
                    controlsCard
                    logCard
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("IOSJB")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("v\(String(cString: iosjb_version()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            sink.append("device=\(machineIdentifier()) system=\(UIDevice.current.systemVersion)")
            sink.append("model=\(UIDevice.current.model) name=\(UIDevice.current.name)")
        }
        .onReceive(timer) { _ in
            running = iosjb_is_running() != 0
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target")
                .font(.headline)
            LabeledContent("iOS", value: UIDevice.current.systemVersion)
            LabeledContent("Machine", value: machineIdentifier())
            LabeledContent("Expected", value: "iPhone15,3 / A16")
            LabeledContent("CVE window", value: vulnerabilityWindow() ? "open" : "patched")
            LabeledContent("Probe", value: running ? "running" : "idle")
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Authorized research only", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The race can corrupt kernel state and reboot the device. A confirmed stale write is not controlled kernel read/write or a jailbreak.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !vulnerabilityWindow() {
                Text("CVE-2026-112514 is fixed on iOS 27.2 and later. The start button is disabled.")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $mode) {
                Text("Precision UAF oracle").tag(0)
                Text("Zone reclaim probe").tag(1)
            }
            .pickerStyle(.segmented)

            if mode == 0 {
                stepperRow("Iterations", value: $iterations, range: 1...5000, step: 50)
                stepperRow("Senders", value: $senders, range: 1...16, step: 1)
                stepperRow("Spray sockets", value: $sprayCount, range: 1...128, step: 8)
                stepperRow("Close delay", value: $closeDelay, range: 0...2000, step: 25, suffix: " us")
            } else {
                Text("Allocates and frees socket objects, sprays 832-byte OOL messages, then checks fresh socket fields for the marker. This mode does not trigger the race.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    guard vulnerabilityWindow() else {
                        sink.append("[!] refusing: this iOS version is outside the vulnerable window")
                        return
                    }
                    sink.append("--- start ---")
                    let result = iosjb_start(
                        Int32(mode),
                        Int32(iterations),
                        Int32(senders),
                        Int32(sprayCount),
                        Int32(closeDelay)
                    )
                    if result != 0 {
                        sink.append("[!] start failed (\(result))")
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || !vulnerabilityWindow())

                Button {
                    iosjb_stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!running)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    sink.clear()
                }
                .font(.caption)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(sink.text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log-bottom")
                }
                .frame(minHeight: 260, maxHeight: 420)
                .onChange(of: sink.text) { _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String = ""
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
        .font(.subheadline)
    }
}

extension LogSink {
    func clear() {
        text = ""
    }
}

