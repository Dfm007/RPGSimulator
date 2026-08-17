import SwiftUI
import WebKit

struct RPGWebView: UIViewRepresentable {
    let gamePath: URL
    @Binding var isLoading: Bool
    let onWebViewCreated: ((WKWebView) -> Void)?

    init(gamePath: URL, isLoading: Binding<Bool> = .constant(false), onWebViewCreated: ((WKWebView) -> Void)? = nil) {
        self.gamePath = gamePath
        self._isLoading = isLoading
        self.onWebViewCreated = onWebViewCreated
    }

    init(folderURL: URL, onWebViewCreated: ((WKWebView) -> Void)? = nil) {
        self.gamePath = folderURL
        self._isLoading = .constant(false)
        self.onWebViewCreated = onWebViewCreated
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        contentController.add(context.coordinator, name: "bridgeReady")
        contentController.add(context.coordinator, name: "debugLog")
        contentController.add(context.coordinator, name: "saveData")

        let bridgeScript = WKUserScript(
            source: RPGWebView.bridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(bridgeScript)

        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let indexURL = gamePath.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            webView.loadFileURL(indexURL, allowingReadAccessTo: gamePath)
            context.coordinator.log("✅ 加载 index.html")
        } else {
            context.coordinator.log("❌ index.html 不存在")
        }

        DispatchQueue.main.async {
            self.onWebViewCreated?(webView)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(gamePath: gamePath)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let gamePath: URL
        let saveDir: URL
        private let logFileURL: URL
        private weak var webView: WKWebView?
        private var hasRestoredSaves = false

        init(gamePath: URL) {
            self.gamePath = gamePath
            self.saveDir = gamePath.appendingPathComponent("save")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logFileURL = docs.appendingPathComponent("bridge_log.txt")
            super.init()
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            log("===== Bridge 初始化 =====")
            log("游戏路径: \(gamePath.path)")
            log("存档目录: \(saveDir.path)")
        }

        func log(_ message: String) {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            let line = "[\(timestamp)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logFileURL)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "bridgeReady":
                log("📨 \(message.body)")
            case "debugLog":
                log("🐛 \(message.body)")
            case "saveData":
                handleSaveData(message: message)
            default:
                log("⚠️ 未知消息: \(message.name)")
            }
        }

        // MARK: - ⭐ 接收保存数据（核心功能）
        private func handleSaveData(message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let fileId = dict["fileId"] as? Int,
                  let dataString = dict["data"] as? String else {
                log("⚠️ 保存数据格式错误")
                return
            }
            
            let fileName = "file\(fileId).rpgsave"
            let fileURL = saveDir.appendingPathComponent(fileName)
            
            log("💾 收到保存数据: file\(fileId), 长度: \(dataString.count)")
            
            // 保存到文件
            do {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✅ 保存成功: \(fileName)")
            } catch {
                log("❌ 保存失败: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            log("🌐 页面加载完成")

            restoreSavesIfNeeded(in: webView)

            let script = RPGWebView.bridgeJavaScript()
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log("❌ 注入失败: \(error)")
                } else {
                    self.log("✅ 桥接注入成功")
                }
            }
        }

                // MARK: - ⭐ 读档：把 save/*.rpgsave 写回 localStorage
                private func restoreSavesIfNeeded(in webView: WKWebView) {
            guard !hasRestoredSaves else { return }
            hasRestoredSaves = true

            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil) else {
                log("⚠️ 无法读取存档目录")
                return
            }
            let saves = files.filter { $0.pathExtension == "rpgsave" }

            var writeStmts = ""
            var keepKeys: [String] = []
            var count = 0
            for url in saves {
                let base = url.deletingPathExtension().lastPathComponent
                guard base.hasPrefix("file"), let fileId = Int(base.dropFirst(4)),
                      let data = try? String(contentsOf: url, encoding: .utf8),
                      let literal = jsStringLiteral(data) else {
                    continue
                }
                let key = "RPG File\(fileId)"
                keepKeys.append(key)
                writeStmts += "localStorage.setItem('\(key)', \(literal));"
                count += 1
            }

            let keepList = keepKeys.map { "'\($0)'" }.joined(separator: ",")
            let cleanupJS = """
            (function(){
                var keep = [\(keepList)];
                var doomed = [];
                for (var i = 0; i < localStorage.length; i++) {
                    var k = localStorage.key(i);
                    if (k && k.indexOf('RPG File') === 0) {
                        if (keep.indexOf(k) === -1) { doomed.push(k); }
                    }
                }
                for (var j = 0; j < doomed.length; j++) { localStorage.removeItem(doomed[j]); }
                return doomed.length;
            })();
            """

            webView.evaluateJavaScript(cleanupJS) { [weak self] _, error in
                guard let self = self else { return }
                if let error = error {
                    self.log("❌ 清理旧存档失败: \(error)")
                    return
                }
                if writeStmts.isEmpty {
                    self.log("ℹ️ 存档目录为空，已清空 localStorage 中的存档")
                    webView.reload()
                    return
                }
                let writeJS = "(function(){\(writeStmts)})();"
                webView.evaluateJavaScript(writeJS) { _, writeError in
                    if let writeError = writeError {
                        self.log("❌ 恢复存档失败: \(writeError)")
                    } else {
                        self.log("✅ 已同步 \(count) 个存档到 localStorage，重新加载")
                        webView.reload()
                    }
                }
            }
        }
        private func jsStringLiteral(_ s: String) -> String? {
            var out = "'"
            for ch in s {
                switch ch {
                case "\\": out += "\\\\"
                case "'":  out += "\\'"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\u{2028}": out += "\\u2028"
                case "\u{2029}": out += "\\u2029"
                default: out.append(ch)
                }
            }
            out += "'"
            return out
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("❌ 导航失败: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log("❌ 临时加载失败: \(error)")
        }
    }

    // MARK: - ⭐ JavaScript 桥接（保存功能）
    private static func bridgeJavaScript() -> String {
        return """
        (function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeReady) {
                window.webkit.messageHandlers.bridgeReady.postMessage('JS 注入开始');
            }

            // ==========================================
            // ⭐ 拦截 StorageManager.save - 备份存档到文件
            // ==========================================
            if (typeof StorageManager !== 'undefined') {
                var originalSave = StorageManager.save;
                StorageManager.save = function(savefileId, json) {
                    // 先执行原始保存
                    var result = originalSave.call(this, savefileId, json);
                    var fileId = savefileId;
                    
                    // 延迟从 localStorage 读取数据并发送给 Native
                    setTimeout(function() {
                        try {
                            var key = 'RPG File' + fileId;
                            var data = localStorage.getItem(key);
                            if (data && data.length > 100) {
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                                    window.webkit.messageHandlers.saveData.postMessage({
                                        fileId: fileId,
                                        data: data
                                    });
                                    console.log('📤 存档已备份，长度: ' + data.length);
                                }
                            } else {
                                console.warn('⚠️ localStorage 中没有找到存档数据: ' + key);
                            }
                        } catch(e) {
                            console.error('备份失败:', e);
                        }
                    }, 500);
                    
                    return result;
                };
            }

            // ==========================================
            // ⭐ 拦截 localStorage.setItem - 直接捕获
            // ==========================================
            var originalSetItem = localStorage.setItem;
            localStorage.setItem = function(key, value) {
                originalSetItem.call(this, key, value);
                
                if (key && key.indexOf('RPG File') === 0 && value && value.length > 100) {
                    var fileId = parseInt(key.replace('RPG File', ''));
                    if (!isNaN(fileId) && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.saveData) {
                        window.webkit.messageHandlers.saveData.postMessage({
                            fileId: fileId,
                            data: value
                        });
                        console.log('📤 localStorage.setItem 直接捕获: ' + key + ', 长度: ' + value.length);
                    }
                }
            };

            console.log('✅ 桥接注入完成 - 保存功能已启用');
        })();
        """
    }
}
