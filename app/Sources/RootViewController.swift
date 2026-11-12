import UIKit
import WebKit
import SafariServices
import PhotosUI
import UniformTypeIdentifiers

final class RootViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate {

    private lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = .default()                 // DOM Storage / Cookie 持久化
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isTextInteractionEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true   // window.open 交给 createWebViewWith
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never   // 页面自己用 env(safe-area-inset-*)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)
        web.allowsBackForwardNavigationGestures = true
        return web
    }()

    private let overlay = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let detailView = UITextView()
    private let restartButton = UIButton(type: .system)

    private var timer: Timer?
    private var waited: TimeInterval = 0
    private var pendingUpload: (([URL]?) -> Void)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        boot()
    }

    // MARK: - UI

    private func setupWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupOverlay() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.startAnimating()
        overlay.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在准备运行时…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .white
        overlay.addSubview(statusLabel)

        restartButton.translatesAutoresizingMaskIntoConstraints = false
        restartButton.setTitle("重试", for: .normal)
        restartButton.setTitleColor(.white, for: .normal)
        restartButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        restartButton.layer.cornerRadius = 10
        restartButton.layer.borderWidth = 1
        restartButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        restartButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        restartButton.isHidden = true
        restartButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        overlay.addSubview(restartButton)

        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.isHidden = true
        detailView.isEditable = false
        detailView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textColor = .white
        detailView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        detailView.layer.cornerRadius = 10
        detailView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        overlay.addSubview(detailView)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -60),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -28),
            restartButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            restartButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            detailView.topAnchor.constraint(equalTo: restartButton.bottomAnchor, constant: 18),
            detailView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
            detailView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
            detailView.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Boot

    private func boot() {
        NodeRuntime.shared.bootTrace("app: boot")
        DispatchQueue.global(qos: .userInitiated).async {
            let error = NodeRuntime.shared.prepare { text in
                DispatchQueue.main.async { self.statusLabel.text = text }
            }
            DispatchQueue.main.async {
                if let error = error {
                    NodeRuntime.shared.bootTrace("app: prepare failed")
                    self.showFatal(error)
                    return
                }
                NodeRuntime.shared.bootTrace("app: prepare ok, starting node")
                self.statusLabel.text = "正在启动本地服务（DSH + 网关）…"
                NodeRuntime.shared.start()
                self.startPolling(limit: 90)
            }
        }
    }

    private func startPolling(limit: TimeInterval) {
        timer?.invalidate()
        waited = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.waited += 0.2
            if let urlString = NodeRuntime.shared.readGatewayURL(), let url = URL(string: urlString) {
                self.timer?.invalidate()
                self.timer = nil
                self.statusLabel.text = "正在加载…"
                self.webView.load(URLRequest(url: url))
                return
            }
            // 启动失败时 mobile-boot.mjs 只写错误文件并挂住线程，直接显示原因
            if let error = NodeRuntime.shared.mobileError() {
                self.timer?.invalidate()
                self.timer = nil
                self.showFatal("本地服务启动失败")
                self.detailView.text = error
                return
            }
            if self.waited >= limit {
                self.timer?.invalidate()
                self.timer = nil
                self.showFatal("等待本地服务超时（\(Int(limit)) 秒）")
            } else if self.waited >= 20 {
                self.statusLabel.text = "首次启动正在解压 / 初始化，请稍候…\n已等待 \(Int(self.waited)) 秒"
            }
        }
    }

    private func showFatal(_ message: String) {
        overlay.isHidden = false
        spinner.stopAnimating()
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        restartButton.isHidden = false
        detailView.isHidden = false
        detailView.text = NodeRuntime.shared.diagnostics()
        print("[xiaobai] fatal:", message)
    }

    /// 「重试」与 `xiaobai://restart` 共用。
    ///
    /// 说明：iOS 上 Node 与 App 同进程，`node::Start` 一旦进入事件循环就无法从外部停掉，
    /// 所以这里做的是「清入口 + 重新探活 + 重新加载」；只有 Node 线程真的退出了才需要重开 App。
    @objc private func retryTapped() {
        restartButton.isHidden = true
        detailView.isHidden = true
        overlay.isHidden = false
        statusLabel.textColor = .white
        statusLabel.text = "正在重启本地服务…"
        spinner.startAnimating()

        NodeRuntime.shared.probeHealth { ok in
            if ok {
                if let s = NodeRuntime.shared.readGatewayURL(), let u = URL(string: s) {
                    self.overlay.isHidden = true
                    self.spinner.stopAnimating()
                    self.webView.load(URLRequest(url: u))
                } else {
                    self.startPolling(limit: 30)
                }
            } else {
                NodeRuntime.shared.resetGatewayURL()
                self.startPolling(limit: 30)
            }
        }
    }

    // MARK: - 生命周期

    @objc private func appWillResignActive() {
        // 给未落盘的会话约 30 秒写完
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "xiaobai-flush") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    @objc private func appDidBecomeActive() {
        endBackgroundTask()
        guard overlay.isHidden else { return }
        NodeRuntime.shared.probeHealth { ok in
            if !ok {
                self.overlay.isHidden = false
                self.showFatal("本地服务已停止响应，请点「重试」或重启 App。")
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        overlay.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if overlay.isHidden { showFatal("页面加载失败：" + error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // 自定义 scheme：xiaobai://restart
        if url.scheme == "xiaobai" {
            decisionHandler(.cancel)
            retryTapped()
            return
        }

        let host = url.host ?? ""
        let loopback = (host == "127.0.0.1" || host == "localhost")

        if loopback {
            // 导出/下载：/novel/export 与网关的一次性 /download 交给 URLSession 下载后分享
            // （WKWebView 的下载代理拿不到 blob，也不给文件名）
            if url.path.hasPrefix("/novel/export") || url.path.hasPrefix("/download") {
                decisionHandler(.cancel)
                downloadExport(url)
                return
            }
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            // 外部域名用 Safari 打开，用户才有返回入口
            decisionHandler(.cancel)
            present(SFSafariViewController(url: url), animated: true)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate：JS 对话框 / window.open

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        DispatchQueue.main.async { self.present(alert, animated: true) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        DispatchQueue.main.async { self.present(alert, animated: true) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        DispatchQueue.main.async { self.present(alert, animated: true) }
    }

    /// window.open / target=_blank 默认会被丢掉：本地页面在当前 WebView 打开，
    /// 导出下载与外部域名分别交给下载任务 / SFSafariViewController。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme == "xiaobai" {
            retryTapped()
            return nil
        }
        let host = url.host ?? ""
        if host == "127.0.0.1" || host == "localhost" {
            if url.path.hasPrefix("/novel/export") || url.path.hasPrefix("/download") {
                downloadExport(url)
            } else {
                webView.load(URLRequest(url: url))
            }
        } else if url.scheme == "http" || url.scheme == "https" {
            present(SFSafariViewController(url: url), animated: true)
        }
        return nil
    }

    // MARK: - 上传（相机 / 相册 / 文件）

    private func finishUpload(_ urls: [URL]?) {
        pendingUpload?(urls)
        pendingUpload = nil
    }

    private func takePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            finishUpload(nil)
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickPhotos() {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = 1
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.85) else {
            finishUpload(nil)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(Int(Date().timeIntervalSince1970)).jpg")
        do {
            try data.write(to: url)
            finishUpload([url])
        } catch {
            finishUpload(nil)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        finishUpload(nil)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            finishUpload(nil)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.85) else {
                DispatchQueue.main.async { self.finishUpload(nil) }
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-\(Int(Date().timeIntervalSince1970)).jpg")
            try? data.write(to: url)
            DispatchQueue.main.async { self.finishUpload([url]) }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishUpload(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishUpload(nil)
    }

    // MARK: - 导出下载

    private func downloadExport(_ url: URL) {
        overlay.isHidden = false
        spinner.startAnimating()
        statusLabel.textColor = .white
        statusLabel.text = "正在导出…"
        detailView.isHidden = true
        restartButton.isHidden = true

        URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, err in
            guard let self = self else { return }
            guard let tmp = tmp else {
                DispatchQueue.main.async {
                    self.showFatal("导出失败：" + (err?.localizedDescription ?? "未知错误"))
                }
                return
            }
            let name = resp?.suggestedFilename ?? "export.txt"
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: tmp, to: dst)
            DispatchQueue.main.async {
                self.overlay.isHidden = true
                self.spinner.stopAnimating()
                let share = UIActivityViewController(activityItems: [dst], applicationActivities: nil)
                if let pop = share.popoverPresentationController {
                    pop.sourceView = self.view
                    pop.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                }
                self.present(share, animated: true)
            }
        }.resume()
    }
}

/// `<input type=file>` 的回调是 iOS 18.4 才新增的；更早的系统里 WKWebView 根本没有文件选择器，
/// 所以整段放在可用性受控的扩展里，避免低版本编译报错。
@available(iOS 18.4, *)
extension RootViewController {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        pendingUpload = completionHandler
        let sheet = UIAlertController(title: "添加附件",
                                      message: "图片附件暂不可用（缺 iOS 版 sharp），建议用文本或 docx",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "拍照", style: .default) { _ in self.takePhoto() })
        sheet.addAction(UIAlertAction(title: "从相册选择", style: .default) { _ in self.pickPhotos() })
        sheet.addAction(UIAlertAction(title: "选择文件", style: .default) { _ in self.pickFiles() })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in self.finishUpload(nil) })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(sheet, animated: true)
    }
}
