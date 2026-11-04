import UIKit
import WebKit

final class RootViewController: UIViewController, WKNavigationDelegate {
    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: config)
    }()

    private let overlay = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let detailView = UITextView()

    private var timer: Timer?
    private var waited: TimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupOverlay()
        boot()
    }

    // MARK: - UI

    private func setupWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
        overlay.backgroundColor = .systemBackground
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        overlay.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在准备运行时（首次启动约 1 分钟）…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        overlay.addSubview(statusLabel)

        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.isHidden = true
        detailView.isEditable = false
        detailView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textColor = .label
        detailView.backgroundColor = .secondarySystemBackground
        detailView.layer.cornerRadius = 10
        detailView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        overlay.addSubview(detailView)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -40),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -32),
            detailView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            detailView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 20),
            detailView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20),
            detailView.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Boot

    private func boot() {
        DispatchQueue.global(qos: .userInitiated).async {
            let error = NodeRuntime.shared.prepare()
            DispatchQueue.main.async {
                if let error = error {
                    self.showFatal(error)
                    return
                }
                self.statusLabel.text = "正在启动本地服务…"
                NodeRuntime.shared.start()
                self.startPolling()
            }
        }
    }

    private func startPolling() {
        timer?.invalidate()
        waited = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.waited += 0.5
            if let urlString = NodeRuntime.shared.readAppURL(), let url = URL(string: urlString) {
                self.timer?.invalidate()
                self.timer = nil
                self.statusLabel.text = "正在加载工作台…"
                self.webView.load(URLRequest(url: url))
                return
            }
            if self.waited >= 120 {
                self.timer?.invalidate()
                self.timer = nil
                self.showFatal("等待本地服务超时（120 秒）")
            } else if self.waited >= 20 {
                self.statusLabel.text = "首次启动正在解压/初始化，请稍候…\n已等待 \(Int(self.waited)) 秒"
            }
        }
    }

    private func showFatal(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        detailView.isHidden = false
        detailView.text = NodeRuntime.shared.diagnostics()
        print("[xiaobai] fatal:", message)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        overlay.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel.text = "页面加载失败：" + error.localizedDescription
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // 站内（127.0.0.1 / localhost）留在 App 内，其余交给系统浏览器
        let host = url.host ?? ""
        if host == "127.0.0.1" || host == "localhost" || url.scheme == "app" {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
