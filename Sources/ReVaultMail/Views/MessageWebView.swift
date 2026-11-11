import SwiftUI
import WebKit

/// HTML письма как в Spark: вёрстка письма в своей ширине, если шире колонки, письмо целиком
/// уменьшается под ширину (а не сминается по буквам). Скрипты письма выключены, высота по содержимому,
/// прокрутка отдаётся родителю. Показывается только после первой подгонки, без «прогрузки как сайт».
struct MessageWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    @Binding var ready: Bool
    var onMeasured: ((CGFloat) -> Void)? = nil
    /// Масштаб текста (⌘+ / ⌘-): pageZoom WebKit, как масштаб в браузере. Высота из скрипта
    /// приходит в CSS-пикселях, поэтому умножается на него.
    var zoom: CGFloat = 1

    /// Одно хранилище на все письма: картинки кэшируются между письмами и при повторном раскрытии.
    @MainActor static let dataStore = WKWebsiteDataStore.nonPersistent()

    final class PassThroughWebView: WKWebView {
        var onResize: (() -> Void)?
        private var lastWidth: CGFloat = 0
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if abs(newSize.width - lastWidth) > 1 { lastWidth = newSize.width; onResize?() }
        }
    }

    /// Обработчик сообщений без сильной ссылки на координатор (иначе контроллер скриптов держит его вечно).
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ t: Coordinator) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.received(message)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = Self.dataStore
        config.suppressesIncrementalRendering = true
        // свой скрипт в отдельном мире работает и при выключенном JS письма: следит за размером
        // (ResizeObserver, догрузка картинок, смена ширины) и присылает высоту, без таймеров
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: Self.observerJS, injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true, in: .defaultClient))
        ucc.add(WeakHandler(context.coordinator), contentWorld: .defaultClient, name: "rvmHeight")
        let wv = PassThroughWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        wv.pageZoom = zoom
        wv.onResize = { [weak wv, weak coordinator = context.coordinator] in
            guard let wv, let coordinator, coordinator.finished else { return }
            coordinator.fit(wv)
        }
        return wv
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "rvmHeight", contentWorld: .defaultClient)
        wv.stopLoading()
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        if abs(wv.pageZoom - zoom) > 0.001 {
            wv.pageZoom = zoom
            if context.coordinator.finished { context.coordinator.fit(wv) }
        }
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        context.coordinator.finished = false
        wv.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    /// Запрет того, что может увести карточку на живой сайт: фреймы, формы, плагины, base.
    /// Картинки и стили грузятся как обычно.
    static let csp = "frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    static func wrap(_ html: String) -> String {
        // meta refresh и base письма выкидываем до загрузки: навигация из карточки не нужна никогда
        var body = html.replacingOccurrences(of: "<meta[^>]*http-equiv\\s*=\\s*[\"']?refresh[^>]*>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<base\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        // пиксели трекинга и пустые строки в хвосте (после среза цитаты) давали дыру под подписью
        body = body.replacingOccurrences(of: CleanText.pixelPattern, with: "", options: [.regularExpression, .caseInsensitive])
        body = trimTrailingBlank(body)
        // Цвета по умолчанию стоят на html, а не на body: тогда bgcolor, text и style на <body> самого
        // письма (тёмные рассылки) выигрывают, и белый текст не оказывается на белом фоне.
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html{overflow:hidden;background:#fff;color:#1d1d1f;font:14px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.45}
        :where(body){margin:0;padding:2px 0}
        p,div,span,td{overflow-wrap:break-word}
        img{max-width:100%;height:auto}
        pre{white-space:pre-wrap}
        blockquote{margin:0 0 0 .8ex;border-left:2px solid #ddd;padding-left:1ex;color:#555}
        a{color:#0a66c2}
        </style></head><body><div id="rvm-root">\(body)</div></body></html>
        """
    }

    /// Срезает <br>, &nbsp; и пустые div/p в конце письма, сколько бы закрывающих тегов ни стояло после них.
    static func trimTrailingBlank(_ html: String) -> String {
        // хвост ищется только в последних 4 000 знаках: регулярка с якорем в конце на большой рассылке медленная
        let cut = html.index(html.endIndex, offsetBy: -min(4000, html.count))
        let head = String(html[..<cut])
        var s = String(html[cut...])
        let pattern = "(?:\\s|&nbsp;|<br\\s*/?>|<(div|p|span)\\b[^>]*>(?:\\s|&nbsp;|<br\\s*/?>)*</\\1>)+((?:\\s*</[a-z0-9]+>)*\\s*)$"
        while true {
            let t = s.replacingOccurrences(of: pattern, with: "$2", options: [.regularExpression, .caseInsensitive])
            if t == s { return head + s }
            s = t
        }
    }

    /// Ширина вёрстки письма больше колонки: масштабируем корень письма целиком. Возвращает итоговую высоту.
    /// Высота берётся по корню письма, а не по документу, поэтому может и уменьшаться.
    static let fitJS = """
    (function(){
      var root=document.getElementById('rvm-root'); if(!root) return 0;
      root.style.zoom=1;
      var vw=window.innerWidth;
      var w=Math.max(root.scrollWidth, document.documentElement.scrollWidth);
      var z=(w > vw + 2) ? Math.max(0.35, vw / w) : 1;
      root.style.zoom=z;
      return Math.ceil(root.getBoundingClientRect().height) + 6;
    })()
    """

    /// То же самое, но само: на каждое изменение размера корня, догрузку картинки и смену ширины окна.
    static let observerJS = """
    (function(){
      var pending=false, lastW=-1, lastH=-1;
      function fit(){
        pending=false;
        var root=document.getElementById('rvm-root'); if(!root) return;
        root.style.zoom=1;
        var vw=window.innerWidth;
        var w=Math.max(root.scrollWidth, document.documentElement.scrollWidth);
        var z=(w > vw + 2) ? Math.max(0.35, vw / w) : 1;
        root.style.zoom=z;
        var h=Math.ceil(root.getBoundingClientRect().height) + 6;
        if(h===lastH && vw===lastW) return;
        lastH=h; lastW=vw;
        window.webkit.messageHandlers.rvmHeight.postMessage(h);
      }
      function schedule(){ if(pending) return; pending=true; setTimeout(fit, 16); }
      function start(){
        var root=document.getElementById('rvm-root'); if(!root) return;
        if(window.ResizeObserver){ new ResizeObserver(schedule).observe(root); }
        document.addEventListener('load', function(e){ if(e.target && e.target.tagName==='IMG') schedule(); }, true);
        document.addEventListener('error', function(e){ if(e.target && e.target.tagName==='IMG') schedule(); }, true);
        window.addEventListener('resize', schedule);
        schedule();
      }
      if(document.readyState==='loading'){ document.addEventListener('DOMContentLoaded', start); } else { start(); }
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MessageWebView
        var loaded: String?
        var finished = false
        init(_ p: MessageWebView) { parent = p }

        func received(_ message: WKScriptMessage) {
            let h = (message.body as? CGFloat) ?? CGFloat((message.body as? Double) ?? Double((message.body as? Int) ?? 0))
            DispatchQueue.main.async { self.apply(h) }
        }

        private func apply(_ css: CGFloat) {
            let h = (css * parent.zoom).rounded(.up)
            if h > 0, abs(h - parent.height) > 1 { parent.height = h }
            if h > 0 { parent.onMeasured?(h) }
            if !parent.ready { parent.ready = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            fit(webView)
            // страховка, если скрипт-наблюдатель не отработал: карточка не остаётся невидимой
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.fit(webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !parent.ready { parent.ready = true }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !parent.ready { parent.ready = true }
        }

        func fit(_ webView: WKWebView) {
            webView.evaluateJavaScript(MessageWebView.fitJS) { [weak self] r, _ in
                let h = (r as? CGFloat) ?? CGFloat((r as? Double) ?? 0)
                DispatchQueue.main.async { self?.apply(h) }
            }
        }

        /// Карточка письма никуда не переходит: разрешена только наша собственная загрузка about:blank.
        /// Клик по ссылке открывает её в браузере; meta refresh, фреймы и формы отменяются.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.navigationType == .linkActivated {
                if let url, Self.isExternal(url) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            if action.targetFrame?.isMainFrame == true, url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        /// target="_blank": новое окно не создаём, ссылку открываем в браузере.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.navigationType == .linkActivated, let url = action.request.url, Self.isExternal(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        static func isExternal(_ url: URL) -> Bool {
            ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "")
        }
    }
}

/// Тело письма в HTML. Высота запоминается по письму: при повторном раскрытии карточка сразу
/// встаёт в свой размер, а до первой подгонки держит место заглушкой нужной высоты.
struct HTMLBody: View {
    let html: String
    let cacheKey: String
    @State private var height: CGFloat
    @State private var ready = false

    @MainActor private static var heights: [String: CGFloat] = [:]

    let zoom: CGFloat

    init(html: String, cacheKey: String? = nil, zoom: Double = 1) {
        self.html = html
        self.zoom = CGFloat(zoom)
        // высота зависит от масштаба: у каждого свой замер
        let key = (cacheKey ?? String(html.hashValue)) + (zoom == 1 ? "" : "|z\(Int((zoom * 100).rounded()))")
        self.cacheKey = key
        _height = State(initialValue: Self.heights[key] ?? Self.estimate(html) * CGFloat(zoom))
    }

    /// Грубая оценка до первого замера: по объёму HTML, в разумных пределах.
    private static func estimate(_ html: String) -> CGFloat {
        min(900, max(80, CGFloat(html.utf8.count) / 30))
    }

    var body: some View {
        MessageWebView(html: html, height: $height, ready: $ready,
                       onMeasured: { h in Self.heights[cacheKey] = h }, zoom: zoom)
            .frame(height: height)
            .opacity(ready ? 1 : 0)
            .overlay(alignment: .topLeading) {
                if !ready { ProgressView().controlSize(.small).padding(.top, 8).frame(maxWidth: .infinity) }
            }
            .animation(.easeOut(duration: 0.15), value: ready)
    }
}
