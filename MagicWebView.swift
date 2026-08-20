//
//  MagicWebView.swift
//  Мост между нативным Hub и Web App.
//
//  ГЛАВНОЕ: WKWebView без единого элемента браузера — ни адресной строки,
//  ни кнопок, ни индикатора загрузки. Зритель видит только приложение.
//

import SwiftUI
import WebKit

struct MagicWebView: UIViewRepresentable {

    let app: MagicApp
    @ObservedObject var core: MagicCore

    func makeCoordinator() -> Coordinator { Coordinator(core: core, app: app) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()

        // Канал JS → Swift
        content.add(context.coordinator, name: "magichub")

        // Скрипт, который сообщает web-приложению, что оно внутри Hub.
        // Выполняется ДО загрузки страницы, поэтому magic-sdk.js сразу
        // выбирает нативный транспорт вместо Web Bluetooth.
        let boot = """
        window.__MAGIC_HUB__ = { version: '0.3', platform: 'ios' };
        document.documentElement.style.setProperty('-webkit-user-select','none');
        document.documentElement.style.setProperty('-webkit-touch-callout','none');
        """
        content.addUserScript(WKUserScript(source: boot,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))

        config.userContentController = content
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.bounces = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.web = web

        load(app: app, into: web)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func load(app: MagicApp, into web: WKWebView) {
        if app.url.hasPrefix("local://") {
            // Приложение лежит внутри Hub — работает всегда, без интернета
            let rel = String(app.url.dropFirst("local://".count))
            let parts = rel.split(separator: "/")
            let folder = parts.count > 1 ? String(parts[0]) : ""
            let file = String(parts.last ?? "index.html")
            let name = (file as NSString).deletingPathExtension
            let ext  = (file as NSString).pathExtension

            if let url = Bundle.main.url(forResource: name, withExtension: ext,
                                         subdirectory: folder.isEmpty ? nil : "WebApps/\(folder)") {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else if let url = URL(string: app.url) {
            web.load(URLRequest(url: url))
        }
    }

    // MARK: - Координатор: приём команд из JS

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let core: MagicCore
        let app: MagicApp
        weak var web: WKWebView?

        init(core: MagicCore, app: MagicApp) {
            self.core = core
            self.app = app
            super.init()

            // Сообщения от пульта уходят в JS
            core.onRemoteMessage = { [weak self] raw in
                self?.push(["ev": "message", "raw": raw])
            }
            core.onStatusChange = { [weak self] state in
                guard let self = self else { return }
                self.push(self.statusDict(state))
            }
        }

        /// Собрать статус БЕЗ nil-значений.
        /// JSONSerialization падает на Optional, поэтому battery добавляем только если он есть.
        func statusDict(_ state: String) -> [String: Any] {
            var d: [String: Any] = ["ev": "status",
                                    "state": state,
                                    "connected": core.remoteConnected]
            if let b = core.remoteBattery { d["battery"] = b }
            return d
        }

        /// Swift → JS
        func push(_ obj: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: obj),
                  let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.web?.evaluateJavaScript("window.__magicReceive && window.__magicReceive(\(s));")
            }
        }

        /// JS → Swift
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let op = body["op"] as? String else { return }

            switch op {
            case "connect":
                push(statusDict(core.remoteConnected ? "connected" : "connecting"))
                if !core.remoteConnected { core.startScanRemote() }

            case "disconnect":
                core.disconnectRemote()

            case "send":
                if let msg = body["msg"] as? [String: Any] { core.sendToRemote(msg) }

            case "devices.list":
                let list = core.devices.map { d -> [String: Any] in
                    ["id": d.id, "name": d.name, "type": d.type,
                     "online": d.online, "battery": d.battery,
                     "modes": d.modes, "mode": d.currentMode, "commands": d.commands]
                }
                push(["ev": "devices", "list": list])

            case "device.cmd":
                if let id = body["id"] as? String, let c = body["command"] as? String {
                    core.deviceCommand(id, c, value: body["value"] as? Double)
                }

            case "device.set":
                if let id = body["id"] as? String, let k = body["key"] as? String,
                   let v = body["value"] as? Double {
                    core.deviceSetSetting(id, key: k, value: v)
                }

            case "device.mode":
                if let id = body["id"] as? String, let m = body["mode"] as? String {
                    core.deviceSetMode(id, m)
                }

            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Сообщаем приложению текущее состояние сразу после загрузки
            push(statusDict(core.remoteConnected ? "connected" : "disconnected"))
            core.setContext(app: app.id, mode: "")
        }
    }
}
