import Foundation

/// 内嵌 Node 运行时管理：首装拷包 → 启动 node → 工作台地址由 bootstrap 写入 dsh-home/app-url.txt
final class NodeRuntime {
    static let shared = NodeRuntime()

    let documents: URL
    /// 运行时代码副本（runtime / gateway / mobile-boot.mjs / mobile.patch.yml）
    let bundleRoot: URL
    /// 可写数据目录（种子来自包内 dsh-home，之后不再覆盖，保住书稿与登录态）
    let home: URL
    let logURL: URL

    private var started = false

    private init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        bundleRoot = documents.appendingPathComponent("runtime-bundle", isDirectory: true)
        home = documents.appendingPathComponent("dsh-home", isDirectory: true)
        logURL = documents.appendingPathComponent("node.log")
    }

    private var seedBundle: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bundle", isDirectory: true)
    }

    /// 返回 nil 表示准备完成；否则是给用户看的错误原文
    func prepare() -> String? {
        let fm = FileManager.default
        guard let seed = seedBundle,
              fm.fileExists(atPath: seed.appendingPathComponent("mobile-boot.mjs").path) else {
            return "安装包内缺少 bundle 资源（mobile-boot.mjs 未找到）"
        }

        do {
            try fm.createDirectory(at: documents, withIntermediateDirectories: true)

            let entry = bundleRoot.appendingPathComponent("mobile-boot.mjs")
            if fm.fileExists(atPath: entry.path) {
                // 升级：只覆盖运行时代码，dsh-home 原地保留
                for item in ["runtime", "gateway"] {
                    let dst = bundleRoot.appendingPathComponent(item, isDirectory: true)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: seed.appendingPathComponent(item, isDirectory: true), to: dst)
                }
                for item in ["mobile-boot.mjs", "mobile.patch.yml"] {
                    let dst = bundleRoot.appendingPathComponent(item)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: seed.appendingPathComponent(item), to: dst)
                }
                if !fm.fileExists(atPath: home.path) {
                    try fm.copyItem(at: seed.appendingPathComponent("dsh-home", isDirectory: true), to: home)
                }
            } else {
                // 首装：整包拷贝（含 dsh-home 种子，约 300 MB）
                if fm.fileExists(atPath: bundleRoot.path) { try fm.removeItem(at: bundleRoot) }
                try fm.copyItem(at: seed, to: bundleRoot)
            }
        } catch {
            return "准备运行时失败：\(error.localizedDescription)"
        }
        return nil
    }

    func start() {
        guard !started else { return }
        started = true

        let entry = bundleRoot.appendingPathComponent("mobile-boot.mjs").path
        let homePath = home.path
        let rootPath = bundleRoot.path
        let logPath = logURL.path

        // node::Start 会一直占用调用线程跑事件循环，必须放到后台线程
        DispatchQueue.global(qos: .userInitiated).async {
            setenv("XIAOBAI_HOME", homePath, 1)
            setenv("XIAOBAI_DSH_PORT", "3092", 1)
            setenv("GATEWAY_PORT", "3099", 1)
            setenv("HOME", homePath, 1)
            setenv("TMPDIR", NSTemporaryDirectory(), 1)
            FileManager.default.changeCurrentDirectoryPath(rootPath)

            // Node 的 stdout/stderr 落到 node.log，真机排查用
            freopen(logPath, "a+", stdout)
            freopen(logPath, "a+", stderr)

            let args = ["node", "--expose-internals", entry]
            var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            _ = xiaobai_node_start(Int32(cArgs.count), &cArgs)
            for pointer in cArgs { free(pointer) }
        }
    }

    func readAppURL() -> String? {
        let file = home.appendingPathComponent("app-url.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http") ? trimmed : nil
    }

    /// 失败时给用户看的诊断信息：mobile-error.txt + node.log 尾部
    func diagnostics() -> String {
        var parts: [String] = []
        let errorFile = home.appendingPathComponent("mobile-error.txt")
        if let text = try? String(contentsOf: errorFile, encoding: .utf8) {
            parts.append("【启动错误】\n" + text)
        }
        if let handle = try? FileHandle(forReadingFrom: logURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > 8000 ? size - 8000 : 0
            try? handle.seek(toOffset: offset)
            if let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) {
                parts.append("【node.log】\n" + text)
            }
        }
        return parts.isEmpty ? "没有拿到任何日志：可能是内嵌 Node 启动即崩溃" : parts.joined(separator: "\n\n")
    }
}
