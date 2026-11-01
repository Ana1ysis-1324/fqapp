import Flutter
import UIKit
import WebKit

/// iOS 版番茄账号登录插件，功能与 Android 的 FanqieAccountPlugin.kt 对齐。
/// MethodChannel 名必须与 Dart/Android 侧完全一致：fqapp/fanqie_account
///
/// 暴露的方法：
///   - login()        打开 wkWebView 加载番茄登录页，登录成功后回传 cookie 字符串
///   - getCookies()   返回当前已保存的 cookie（字符串）
///   - logout()       清空 cookie
///
/// 注意：Dart 侧调用的方法名以此为基准。若 fqapp 的 Dart 代码用了别的名字，
/// 把下面 handle 分支里的字符串改掉即可（通道名不要动）。
class FanqieAccountPlugin: NSObject, FlutterPlugin, WKNavigationDelegate {
  static let channelName = "fqapp/fanqie_account"
  static let loginUrl = "https://account.fanqie.ivwen.com/account/login"
  private var cookieStore: [String: String] = [:]
  private var loginResult: FlutterResult?
  private var webView: WKWebView?
  private var hostViewController: UIViewController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
    let instance = FanqieAccountPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "login":
      loginResult = result
      openLoginSheet()
    case "getCookies":
      result(cookieString())
    case "logout":
      cookieStore.removeAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func cookieString() -> String {
    return cookieStore.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
  }

  private func openLoginSheet() {
    let config = WKWebViewConfiguration()
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.load(URLRequest(url: URL(string: FanqieAccountPlugin.loginUrl)!))
    self.webView = web

    let vc = UIViewController()
    web.translatesAutoresizingMaskIntoConstraints = false
    vc.view.addSubview(web)
    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: vc.view.topAnchor),
      web.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
      web.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
    ])
    let close = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissSheet))
    vc.navigationItem.rightBarButtonItem = close
    let nav = UINavigationController(rootViewController: vc)
    hostViewController = topViewController()
    hostViewController?.present(nav, animated: true, completion: nil)
  }

  @objc private func dismissSheet() {
    hostViewController?.dismiss(animated: true, completion: nil)
    if let r = loginResult { r(cookieString()); loginResult = nil }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if let http = navigationResponse.response as? HTTPURLResponse,
       let fields = http.allHeaderFields as? [String: String] {
      // 从 Set-Cookie 抽取关键字段
      if let setCookie = fields["Set-Cookie"] {
        for pair in setCookie.components(separatedBy: ",") {
          let kv = pair.components(separatedBy: ";").first ?? ""
          if let eq = kv.firstIndex(of: "=") {
            let k = String(kv[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { cookieStore[k] = v }
          }
        }
      }
    }
    decisionHandler(.allow)
  }

  private func topViewController() -> UIViewController? {
    var vc = UIApplication.shared.keyWindow?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
