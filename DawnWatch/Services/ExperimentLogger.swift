import Foundation
import Combine

/// 本地实验日志：一行一个 JSON 事件，追加写入 JSONL 文件。
/// 不上传、不接第三方 analytics；允许在 App 内清空。
/// 目录可注入——测试用临时目录，App 用 Application Support。
final class ExperimentLogger: ObservableObject {
    @Published private(set) var recentEvents: [ExperimentEvent] = []

    let fileURL: URL
    private let queue = DispatchQueue(label: "dawn.experimentlogger")
    private let encoder = ExperimentEvent.makeEncoder()
    private let memoryLimit = 200

    /// 默认：Application Support/Dawn/experiment.jsonl（单文件，便于整体导出）。
    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Dawn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("experiment.jsonl")
    }

    init(fileURL: URL = ExperimentLogger.defaultFileURL()) {
        self.fileURL = fileURL
        recentEvents = Self.readAll(from: fileURL).suffix(memoryLimit).reversed()
    }

    func log(_ event: ExperimentEvent) {
        let line = event.encodedLine(encoder: encoder)
        if !line.isEmpty {
            queue.sync {
                if let handle = FileHandle(forWritingAtPath: fileURL.path) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data((line + "\n").utf8))
                } else {
                    try? (line + "\n").data(using: .utf8)?.write(to: fileURL)
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentEvents.insert(event, at: 0)
            if self.recentEvents.count > self.memoryLimit {
                self.recentEvents = Array(self.recentEvents.prefix(self.memoryLimit))
            }
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.recentEvents = []
        }
    }

    /// 读取全部事件（旧→新）。文件损坏行跳过。
    static func readAll(from url: URL) -> [ExperimentEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { ExperimentEvent.decode(line: String($0)) }
    }

    /// 导出整份日志文本（分享/AirDrop 用）。
    func exportText() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
