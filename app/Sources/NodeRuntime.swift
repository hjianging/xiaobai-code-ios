import Foundation

/// 内嵌 Node 运行时的安装与启动。
///
/// 布局（都在 App 沙盒内）：
///   Library/Application Support/xiaobai/             ← installRoot（已排除 iCloud 备份）
///     runtime-bundle/                                ← 运行时副本（写入 .bundle-id）
///       mobile-boot.mjs / gateway / runtime / dsh-home / dsh-home-seed / mobile.patch.yml
///     tmp/                                           ← TMPDIR
///
/// 进程内执行 `mobile-boot.mjs`：它同时拉起 DSH 宿主（3092）与本地网关（3099），
/// 把入口地址写到 `dsh-home/gateway-url.txt`，原生壳轮询这个文件加载 WebView。
final class NodeRuntime {
    static let shared = NodeRuntime()

    let installRoot: URL
    let bundleRoot: URL
    let home: URL
    let tmpDir: URL
    let logURL: URL

    private var started = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        installRoot = base.appendingPathComponent("xiaobai", isDirectory: true)
        bundleRoot = installRoot.appendingPathComponent("runtime-bundle", isDirectory: true)
        home = bundleRoot.appendingPathComponent("dsh-home", isDirectory: true)
        tmpDir = installRoot.appendingPathComponent("tmp", isDirectory: true)
        logURL = home.appendingPathComponent("dsh.log")
    }

    private var seedBundle: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bundle", isDirectory: true)
    }

    /// bundle 自带版本号（dsh-home-seed/VERSION，形如 1.5.84-26b8fa95）
    private func seedVersion() -> String? {
        guard let seed = seedBundle else { return nil }
        let f = seed.appendingPathComponent("dsh-home-seed/VERSION")
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 返回 nil 表示准备完成；否则是给用户看的错误原文
    func prepare(progress: @escaping (String) -> Void) -> String? {
        let fm = FileManager.default
        guard let seed = seedBundle,
              fm.fileExists(atPath: seed.appendingPathComponent("mobile-boot.mjs").path) else {
            return "安装包内缺少 bundle 资源（mobile-boot.mjs 未找到）"
        }

        do {
            try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            excludeFromBackup(installRoot)

            let version = seedVersion() ?? "unknown"
            bootTrace("prepare: bundle=\(version)")
            let marker = bundleRoot.appendingPathComponent(".bundle-id")
            let installed = (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = bundleRoot.appendingPathComponent("mobile-boot.mjs")
            let firstInstall = !fm.fileExists(atPath: entry.path)

            if firstInstall {
                if fm.fileExists(atPath: bundleRoot.path) { try fm.removeItem(at: bundleRoot) }
                try fm.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
                // 逐项拷贝：这样进度可见，闪退时也能从 boot-trace 看出卡在哪个目录
                let items = ["runtime", "gateway", "dsh-home", "dsh-home-seed", "mobile-boot.mjs", "mobile.patch.yml"]
                for (i, item) in items.enumerated() {
                    let src = seed.appendingPathComponent(item)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    progress("首次启动：正在解压运行时（\(i + 1)/\(items.count) \(item)）…")
                    bootTrace("copy: \(item) begin")
                    try fm.copyItem(at: src, to: bundleRoot.appendingPathComponent(item))
                    bootTrace("copy: \(item) done")
                }
            } else if installed != version {
                progress("正在升级运行时到 \(version)…")
                // 只覆盖运行时代码与轻量种子，绝不碰 dsh-home（书稿 / 登录态 / Key 都在里面）
                for dir in ["runtime", "gateway", "dsh-home-seed"] {
                    let dst = bundleRoot.appendingPathComponent(dir, isDirectory: true)
                    let src = seed.appendingPathComponent(dir, isDirectory: true)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                }
                for file in ["mobile-boot.mjs", "mobile.patch.yml"] {
                    let dst = bundleRoot.appendingPathComponent(file)
                    let src = seed.appendingPathComponent(file)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                }
            }

            // dsh-home 只在首装铺种子：profiles 已存在就不再动
            if !fm.fileExists(atPath: home.appendingPathComponent("profiles").path) {
                let seedHome = seed.appendingPathComponent("dsh-home", isDirectory: true)
                if fm.fileExists(atPath: seedHome.path) {
                    if fm.fileExists(atPath: home.path) { try fm.removeItem(at: home) }
                    try fm.copyItem(at: seedHome, to: home)
                } else {
                    try fm.createDirectory(at: home, withIntermediateDirectories: true)
                }
            }
            try fm.createDirectory(at: home, withIntermediateDirectories: true)

            try? version.write(to: marker, atomically: true, encoding: .utf8)
            bootTrace("prepare: ok")
        } catch {
            bootTrace("prepare: failed \(error.localizedDescription)")
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
        let caPath = bundleRoot.appendingPathComponent("runtime/ca.pem").path
        let tmpPath = tmpDir.path
        let installPath = installRoot.path

        // node::Start 会一直占用调用线程跑事件循环，必须放到后台线程（不能阻塞 UI）。
        // 注意：GCD 的工作线程栈只有 512KB，V8 初始化会栈溢出直接闪退，
        // 所以这里用自建 Thread 并把栈放大（nodejs-mobile 也是这么做的）。
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            setenv("XB_MOBILE", "1", 1)
            setenv("XB_IOS", "1", 1)
            setenv("XIAOBAI_HOME", homePath, 1)
            setenv("XIAOBAI_DSH_PORT", "3092", 1)
            setenv("GATEWAY_PORT", "3099", 1)
            setenv("HOME", installPath, 1)
            setenv("TMPDIR", tmpPath, 1)
            setenv("NODE_EXTRA_CA_CERTS", caPath, 1)
            FileManager.default.changeCurrentDirectoryPath(rootPath)

            // 兜底：如果当前沙盒写不了 dsh-home，至少让错误落到可读文件
            freopen(logPath, "a+", stdout)
            freopen(logPath, "a+", stderr)

            // iOS 不允许申请可执行内存，V8 必须 --jitless（少了这个参数就是「打开就闪退」）
            let args = ["node", "--expose-internals", "--jitless", entry]
            var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            cArgs.append(nil)                       // argv 必须以 NULL 结尾
            self.bootTrace("node start: \(args.joined(separator: " "))")
            let code = xiaobai_node_start(Int32(args.count), &cArgs)
            self.bootTrace("node exited: \(code)")
            for pointer in cArgs where pointer != nil { free(pointer) }
        }
        thread.name = "xiaobai-node"
        thread.stackSize = 16 * 1024 * 1024
        thread.start()
    }

    /// 网关入口：未登录 = 3099 登录页；已登录 = 3099/app。app-url.txt 是带 token 的 3092 地址。
    func readGatewayURL() -> String? {
        for name in ["gateway-url.txt", "app-url.txt"] {
            let f = home.appendingPathComponent(name)
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("http") { return s }
        }
        return nil
    }

    func resetGatewayURL() {
        try? FileManager.default.removeItem(at: home.appendingPathComponent("gateway-url.txt"))
    }

    /// mobile-boot.mjs 在 iOS 上失败时只写这个文件并挂住线程，不会让 App 闪退
    func mobileError() -> String? {
        let f = home.appendingPathComponent("mobile-error.txt")
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    func probeHealth(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:3099/health") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// 失败时给用户看的诊断：mobile-error.txt + 启动日志 + dsh.log 尾部
    func diagnostics() -> String {
        var parts: [String] = []
        let errorFile = home.appendingPathComponent("mobile-error.txt")
        if let text = try? String(contentsOf: errorFile, encoding: .utf8), !text.isEmpty {
            parts.append("【启动错误】\n" + text)
        }
        let logsDir = home.appendingPathComponent("logs", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
            let latest = items.filter { $0.lastPathComponent.hasPrefix("startup-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .first
            if let f = latest, let text = try? String(contentsOf: f, encoding: .utf8) {
                parts.append("【\(f.lastPathComponent)】\n" + String(text.suffix(4000)))
            }
        }
        if let handle = try? FileHandle(forReadingFrom: logURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > 8000 ? size - 8000 : 0
            try? handle.seek(toOffset: offset)
            if let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8), !text.isEmpty {
                parts.append("【dsh.log 尾部】\n" + text)
            }
        }
        let text = parts.isEmpty ? "没有拿到任何日志：可能是内嵌 Node 启动即崩溃" : parts.joined(separator: "\n\n")
        try? text.write(to: NodeRuntime.documentsLog("diagnostics.txt"), atomically: true, encoding: .utf8)
        return text
    }

    /// 原生侧启动轨迹；闪退时用来判断卡在哪一步（Node 自己的输出在 dsh.log）。
    /// 同时写一份到 Documents/xiaobai-log，用户可以在「文件」App 里直接取出来发给我们。
    func bootTrace(_ message: String) {
        guard let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
        for f in [installRoot.appendingPathComponent("boot-trace.txt"), NodeRuntime.documentsLog("boot-trace.txt")] {
            if let handle = try? FileHandle(forWritingTo: f) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: f)
            }
        }
    }

    /// Documents/xiaobai-log/<name>（配合 Info.plist 的 UIFileSharingEnabled，可在「文件」App 里看到）
    static func documentsLog(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("xiaobai-log", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
