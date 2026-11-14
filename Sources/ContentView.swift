import Darwin
import SwiftUI
import UIKit

final class LogSink: ObservableObject {
    static let shared = LogSink()
    static let logFileURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("IOSJB.log")

    @Published private(set) var text = ""

    private init() {
        let header = "IOSJB \(String(cString: iosjb_version())) 研究终端\n"
        text = header
        try? header.write(to: Self.logFileURL, atomically: true, encoding: .utf8)
    }

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.count > 120_000 {
            text = String(text.suffix(80_000))
        }
        text += trimmed + "\n"
        appendToFile(trimmed + "\n")
    }

    func clear() {
        let header = "IOSJB \(String(cString: iosjb_version())) 研究终端\n"
        text = header
        try? header.write(to: Self.logFileURL, atomically: true, encoding: .utf8)
    }

    private func appendToFile(_ line: String) {
        let data = Data(line.utf8)
        do {
            if FileManager.default.fileExists(atPath: Self.logFileURL.path) {
                let handle = try FileHandle(forWritingTo: Self.logFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: Self.logFileURL, options: .atomic)
            }
        } catch {
            // The UI copy remains available if the Documents write fails.
        }
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

    @State private var mode = 2
    @State private var iterations = 1000.0
    @State private var senders = 6.0
    @State private var sprayCount = 48.0
    @State private var closeDelay = 0.0
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
            .navigationTitle("IOSJB 研究终端")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("v\(String(cString: iosjb_version()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            sink.append("设备标识=\(machineIdentifier()) 系统版本=\(UIDevice.current.systemVersion)")
            sink.append("设备类型=\(UIDevice.current.model) 名称=\(UIDevice.current.name)")
        }
        .onReceive(timer) { _ in
            running = iosjb_is_running() != 0
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("目标设备")
                .font(.headline)
            LabeledContent("iOS 版本", value: UIDevice.current.systemVersion)
            LabeledContent("设备标识", value: machineIdentifier())
            LabeledContent("预期机型", value: "iPhone15,3 / A16")
            LabeledContent("CVE 窗口", value: vulnerabilityWindow() ? "开放" : "已修复")
            LabeledContent("探针状态", value: running ? "运行中" : "空闲")
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("仅限已授权设备研究", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("竞态可能破坏内核状态并导致设备重启。确认 stale write 只代表发生陈旧写入，不代表已获得受控内核读写或完整越狱。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !vulnerabilityWindow() {
                Text("CVE-2026-112514 已在 iOS 27.2 及更高版本修复，开始按钮已禁用。")
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
            Picker("模式", selection: $mode) {
                Text("精确 UAF 检测").tag(0)
                Text("组合竞态").tag(2)
                Text("Zone 回收探针").tag(1)
            }
            .pickerStyle(.segmented)

            if mode != 1 {
                stepperRow("迭代次数", value: $iterations, range: 1...5000, step: 50)
                stepperRow("发送线程", value: $senders, range: 1...16, step: 1)
                stepperRow("喷射 Socket", value: $sprayCount, range: 1...128, step: 8)
                stepperRow("关闭延迟", value: $closeDelay, range: 0...2000, step: 10, suffix: " 微秒")
                if mode == 2 {
                    Text("组合模式依次运行：精确 close/send、8 Socket 多 FD 退役、TCP Timer Socket 退役。建议先用 1000 轮测试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("分配并释放 Socket 对象，喷射 832 字节 OOL Mach 消息，然后检查新 Socket 字段是否出现标记值。此模式不会触发竞态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    guard vulnerabilityWindow() else {
                        sink.append("[!] 已拒绝：当前 iOS 版本不在漏洞窗口内")
                        return
                    }
                    sink.append("--- 开始测试 ---")
                    let result = iosjb_start(
                        Int32(mode),
                        Int32(iterations),
                        Int32(senders),
                        Int32(sprayCount),
                        Int32(closeDelay)
                    )
                    if result != 0 {
                        sink.append("[!] 启动失败（错误码 \(result)）")
                    }
                } label: {
                    Label("开始", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || !vulnerabilityWindow())

                Button {
                    iosjb_stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
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
                Text("运行日志")
                    .font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = sink.text
                    sink.append("[*] 日志已复制到剪贴板")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .font(.caption)
                ShareLink(item: LogSink.logFileURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .font(.caption)
                Button("清空") {
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

