import Cocoa
import WebKit
import Security

// SYNTHETIC ONLY. Never print URLs, errors containing URLs, DOM, or credentials.
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var web: WKWebView!
    var basicChallenges = 0
    var callbackObserved = false
    var cspBlocked = false
    var formActionViolations = 0
    var inputValid = false
    var formFound = false
    var buttonFound = false
    var navigationErrors: [[String: Any]] = []
    var responseStatuses: [Int] = []
    var submitted = false
    var finished = false
    let dir: String
    let credential: String
    let entry: URL
    let origin: URL
    init(dir: String, credential: String) throws {
        self.dir = dir; self.credential = credential
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/entry.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: String]
        entry = URL(string: json["url"]!)!; origin = URL(string: json["origin"]!)!
        super.init()
    }
    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "csp")
        config.userContentController.addUserScript(WKUserScript(source: "document.addEventListener('securitypolicyviolation', e => { if(e.effectiveDirective === 'form-action') window.webkit.messageHandlers.csp.postMessage({formAction:true, customScheme:e.blockedURI.startsWith('pony-native:')}); });", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        web.load(URLRequest(url: entry))
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in self.check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { self.finish(false) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Bool], body["formAction"] == true {
            formActionViolations += 1
            if body["customScheme"] == true { cspBlocked = true }
        }
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let p = challenge.protectionSpace
        guard p.host == "127.0.0.1", p.port == origin.port, p.protocol == "https", challenge.previousFailureCount == 0 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if p.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = p.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count == 1,
           let expected = try? Data(contentsOf: URL(fileURLWithPath: dir + "/cert.der")),
           (SecCertificateCopyData(chain[0]) as Data) == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if p.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            basicChallenges += 1
            completionHandler(.useCredential, URLCredential(user: "owner", password: credential, persistence: .forSession))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "pony-native" {
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            callbackObserved = url.host == "auth" && c?.queryItems?.first(where: { $0.name == "state" })?.value == "synthetic_state_20261020"
            decisionHandler(.cancel) // Never launch an installed custom-scheme application.
        } else {
            decisionHandler(url.scheme == "https" && url.host == "127.0.0.1" && url.port == origin.port ? .allow : .cancel)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !submitted else { return }; submitted = true
        webView.evaluateJavaScript("(() => { const f=document.querySelector('input[name=verification_code]'); const b=document.querySelector('button[value=approve]'); const result={formFound:!!(f && f.form),buttonFound:!!b,inputValid:false}; if(!f || !b) return result; f.value='12AB34CD'; result.inputValid=f.checkValidity(); b.click(); return result; })()") { result, error in
            guard error == nil, let checks = result as? [String: Bool] else { self.finish(false); return }
            self.formFound = checks["formFound"] == true
            self.buttonFound = checks["buttonFound"] == true
            self.inputValid = checks["inputValid"] == true
            if !self.formFound || !self.buttonFound || !self.inputValid { self.finish(false) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse { responseStatuses.append(response.statusCode) }
        decisionHandler(.allow)
    }
    func recordNavigationError(_ error: Error) {
        let e = error as NSError
        // Never stringify error/userInfo: those can contain the secret request URL.
        navigationErrors.append(["domain": e.domain, "code": e.code])
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { recordNavigationError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { recordNavigationError(error) }
    func check() {
        guard !finished, let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/evidence.json")),
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if e["originAccepted"] as? Bool == true && e["cookieAccepted"] as? Bool == true && e["callbackStateValid"] as? Bool == true && e["grantCreated"] as? Bool == true && basicChallenges > 0 && callbackObserved && !cspBlocked && formActionViolations == 0 {
            finish(true)
        }
    }
    func finish(_ ok: Bool) {
        if finished { return }; finished = true
        let report: [String: Any] = ["pass": ok, "basicChallenges": basicChallenges, "callbackObserved": callbackObserved, "cspBlocked": cspBlocked, "domSubmitted": submitted, "formFound": formFound, "buttonFound": buttonFound, "inputValid": inputValid, "formActionViolations": formActionViolations, "navigationErrors": navigationErrors, "responseStatuses": responseStatuses]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) { print(line) }
        exit(ok ? 0 : 1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
do {
    let harness = try Harness(dir: CommandLine.arguments[1], credential: CommandLine.arguments[2])
    harness.start()
    withExtendedLifetime(harness) { RunLoop.main.run() }
} catch { print("FAIL fixture input (redacted)"); exit(1) }
