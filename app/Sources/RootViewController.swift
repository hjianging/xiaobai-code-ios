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
        DispatchQueue.global(qos: .userInitiated).async {
            let error = NodeRuntime.shared.prepare { text in
                DispatchQueue.main.async { self.statusLabel.text = text }
            }
            DispatchQueue.main.async {
                if let error = error {
                    self.showFatal(error)
                    return
                }
                self.statusLabel.text = "正在启动本地服务（DSH + 网关）…"
                NodeRuntime.shared.start()
                self.startPolling(limit: 120)
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

    @objc private func retryTapped() {
        restartButton.isHidden = true
        detailView.isHidden = true
        statusLabel.textColor = .white
        spinner.startAnimating()
        NodeRuntime.shared.resetGatewayURL()
        NodeRuntime.shared.probeHealth { ok in
            if ok {
                self.startPolling(limit: 60)
            } else {
                self.showFatal("本地服务没有响应（127.0.0.1:3099）。请完全退出 App 后重开。")
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
            // 导出：/novel/export 交给 URLSession 下载后分享（WKWebView 拿不到 blob）
            if url.path.hasPrefix("/novel/export") {
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

    // MARK: - 上传（相机 / 相册 / 文件）

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        pendingUpload = completionHandler
        let sheet = UIAlertController(title: "添加附件", message: "图片附件暂不支持，建议用文本或 docx",
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
