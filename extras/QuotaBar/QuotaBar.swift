import AppKit
import Foundation

struct WindowQuota {
    let remaining: Double
    let reset: Date?
}

struct AccountQuota {
    let name: String
    let five: WindowQuota?
    let week: WindowQuota?
    let disabled: Bool
    let unavailable: Bool
    let error: String?
    var usable: Bool {
        !disabled && !unavailable && error == nil &&
        (five?.remaining ?? 0) > 0 && (week?.remaining ?? 0) > 0
    }
}

func totals(_ accounts: [AccountQuota]) -> (five: Double, week: Double, capacity: Int, partial: Bool) {
    let enabled = accounts.filter { !$0.disabled }
    return (enabled.reduce(0) { $0 + ($1.five?.remaining ?? 0) },
            enabled.reduce(0) { $0 + ($1.week?.remaining ?? 0) },
            enabled.count * 100,
            enabled.contains { $0.error != nil || $0.five == nil || $0.week == nil })
}

enum FetchError: Error {
    case failure(String)
    var message: String {
        if case .failure(let text) = self { return text }
        return "Ошибка обновления"
    }
}

struct Router {
    let key: String
    let base: String

    init() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.cpa.gui/config.toml")
        let text = try String(contentsOf: path, encoding: .utf8)
        func value(_ name: String) -> String? {
            let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\"([^\"\\n]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        guard let secret = value("management-secret-key"), !secret.isEmpty else {
            throw FetchError.failure("Нет ключа управления EasyCLIProxyAPI")
        }
        let host = value("host") ?? "127.0.0.1"
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw FetchError.failure("Виджет работает только с локальным роутером")
        }
        let regex = try NSRegularExpression(pattern: "(?m)^port\\s*=\\s*(\\d+)")
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        let port = match.flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) } ?? "8317"
        key = secret
        base = "http://\(host == "::1" ? "[::1]" : host):\(port)/v0/management/"
    }

    func request(_ endpoint: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + endpoint)!)
        request.timeoutInterval = 25
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body = body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.failure("Роутер: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.failure("Не удалось прочитать ответ роутера")
        }
        return json
    }

    func account(_ file: [String: Any]) async -> AccountQuota {
        let name = file["email"] as? String ?? file["name"] as? String ?? "Аккаунт"
        let disabled = file["disabled"] as? Bool ?? false
        let unavailable = file["unavailable"] as? Bool ?? false
        func result(_ five: WindowQuota? = nil, _ week: WindowQuota? = nil, _ error: String? = nil) -> AccountQuota {
            AccountQuota(name: name, five: five, week: week, disabled: disabled, unavailable: unavailable, error: error)
        }
        if disabled { return result() }
        guard let index = file["auth_index"] else { return result(nil, nil, "Нет индекса аккаунта") }
        var token: [String: Any] = file["id_token"] as? [String: Any] ?? [:]
        if let raw = file["id_token"] as? String {
            if let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                token = object
            } else {
                let parts = raw.split(separator: ".")
                if parts.count > 1 {
                    var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    part += String(repeating: "=", count: (4 - part.count % 4) % 4)
                    if let data = Data(base64Encoded: part), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { token = object }
                }
            }
        }
        let auth = token["https://api.openai.com/auth"] as? [String: Any] ?? token
        var header = ["Authorization": "Bearer $TOKEN$", "Content-Type": "application/json", "User-Agent": "codex-tui/0.149.1"]
        if let account = auth["chatgpt_account_id"] as? String ?? token["chatgpt_account_id"] as? String { header["Chatgpt-Account-Id"] = account }
        do {
            let response = try await request("api-call", body: ["authIndex": index, "method": "GET", "url": "https://chatgpt.com/backend-api/wham/usage", "header": header])
            let status = response["status_code"] as? Int ?? 0
            guard status == 200 else { return result(nil, nil, "Квота: HTTP \(status)") }
            var payload = response["body"] as? [String: Any]
            if let raw = response["body"] as? String, let data = raw.data(using: .utf8) {
                payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard let rate = payload?["rate_limit"] as? [String: Any] else { return result(nil, nil, "Нет данных о лимитах") }
            var five: WindowQuota?, week: WindowQuota?
            for key in ["primary_window", "secondary_window"] {
                guard let window = rate[key] as? [String: Any], let used = window["used_percent"] as? Double,
                      let duration = window["limit_window_seconds"] as? Int else { continue }
                let reset = (window["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let quota = WindowQuota(remaining: max(0, min(100, 100 - used)), reset: reset)
                if duration == 18000 { five = quota }
                if duration == 604800 { week = quota }
            }
            let blocked = rate["allowed"] as? Bool == false || rate["limit_reached"] as? Bool == true
            return AccountQuota(name: name, five: five, week: week, disabled: disabled, unavailable: unavailable || blocked, error: nil)
        } catch { return result(nil, nil, (error as? FetchError)?.message ?? "Нет связи с сервисом квот") }
    }

    func fetch() async throws -> [AccountQuota] {
        let response = try await request("auth-files")
        guard let files = response["files"] as? [[String: Any]] else { throw FetchError.failure("Нет списка аккаунтов") }
        let codex = files.filter { ($0["provider"] as? String ?? $0["type"] as? String) == "codex" }
        return await withTaskGroup(of: AccountQuota.self) { group in
            for file in codex { group.addTask { await account(file) } }
            var results: [AccountQuota] = []
            for await value in group { results.append(value) }
            return results.sorted { $0.name < $1.name }
        }
    }
}

@MainActor
final class QuotaBar: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var accounts: [AccountQuota] = []
    var updated: Date?
    var error: String?
    var refreshing = false
    var cycles = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func wake() { refresh() }
    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        render()
        Task {
            do {
                accounts = try await Router().fetch()
                updated = Date()
                error = nil
                cycles += 1
            } catch { self.error = (error as? FetchError)?.message ?? "Роутер недоступен" }
            refreshing = false
            render()
            writeDiagnostics()
        }
    }

    func render() {
        let total = totals(accounts)
        let stale = error != nil || updated == nil || Date().timeIntervalSince(updated ?? .distantPast) > 120
        let label = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        func add(_ text: String, _ color: NSColor) {
            label.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        func color(_ value: Double) -> NSColor {
            if stale || total.partial { return .secondaryLabelColor }
            let fraction = value / Double(max(1, total.capacity))
            return fraction < 0.2 ? .systemRed : fraction < 0.5 ? .systemOrange : .systemGreen
        }
        let suffix = stale ? " ~" : total.partial ? " · нет данных" : ""
        add("5h ", .labelColor)
        add(total.capacity == 0 || total.partial ? "—" : "\(Int(total.five.rounded()))%", color(total.five))
        add("  Weekly ", .labelColor)
        add(total.capacity == 0 || total.partial ? "—" : "\(Int(total.week.rounded()))%", color(total.week))
        add(suffix, .secondaryLabelColor)
        item.button?.attributedTitle = label
        item.button?.toolTip = "Сумма остатков включённых аккаунтов, отдельно для 5h и Weekly. 100% — полная квота одного аккаунта; ёмкость разных подписок может отличаться."
        let menu = NSMenu()
        func info(_ text: String) { let entry = NSMenuItem(title: text, action: nil, keyEquivalent: ""); entry.isEnabled = false; menu.addItem(entry) }
        info("Доступны для запросов сейчас: \(accounts.filter { $0.usable }.count)/\(accounts.count) аккаунтов")
        info("5h и Weekly суммируются отдельно")
        info("100% = полная квота одного аккаунта")
        if let error = error { info("⚠ \(error) · показаны прежние данные") }
        if total.partial { info("⚠ Часть квот неизвестна — сумма неполная") }
        menu.addItem(.separator())
        for account in accounts {
            let state = account.disabled ? "выключен" : account.error ?? (account.usable ? "доступен" : "недоступен")
            info("\(account.name) · \(state)")
            func line(_ title: String, _ quota: WindowQuota?) {
                guard let quota = quota else { info("   \(title): —"); return }
                let reset = quota.reset.map { " · сброс \(DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short))" } ?? ""
                info("   \(title): \(Int(quota.remaining.rounded()))%\(reset)")
            }
            line("5h", account.five); line("Weekly", account.week)
        }
        menu.addItem(.separator())
        if let updated = updated { info("Обновлено \(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))") }
        info("Автообновление каждую минуту")
        let refreshItem = NSMenuItem(title: refreshing ? "Обновляется…" : "Обновить сейчас", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self; refreshItem.isEnabled = !refreshing; menu.addItem(refreshItem)
        let quit = NSMenuItem(title: "Закрыть QuotaBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }

    func writeDiagnostics() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/QuotaBar")
        let total = totals(accounts)
        let data: [String: Any] = ["cycles": cycles, "accounts": accounts.count, "available": accounts.filter { $0.usable }.count,
                                 "fiveRemaining": total.five, "weeklyRemaining": total.week, "capacity": total.capacity,
                                 "partial": total.partial, "updatedAt": updated?.timeIntervalSince1970 ?? 0, "routerError": error != nil]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? json.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    let q = WindowQuota(remaining: 100, reset: nil)
    let empty = WindowQuota(remaining: 0, reset: nil)
    let good = AccountQuota(name: "good", five: q, week: q, disabled: false, unavailable: false, error: nil)
    let weeklyBlocked = AccountQuota(name: "blocked", five: q, week: empty, disabled: false, unavailable: false, error: nil)
    let fiveBlocked = AccountQuota(name: "5h blocked", five: empty, week: q, disabled: false, unavailable: true, error: nil)
    let staleCooldown = AccountQuota(name: "stale cooldown", five: q, week: q, disabled: false, unavailable: true, error: nil)
    let unknown = AccountQuota(name: "unknown", five: nil, week: nil, disabled: false, unavailable: false, error: "offline")
    let disabled = AccountQuota(name: "disabled", five: q, week: q, disabled: true, unavailable: false, error: nil)
    let t = totals([good, weeklyBlocked, unknown, disabled])
    precondition(t.five == 200 && t.week == 100 && t.capacity == 300 && t.partial)
    let independent = totals([good, fiveBlocked, staleCooldown])
    precondition(independent.five == 200 && independent.week == 300 && !independent.partial)
    precondition(!weeklyBlocked.usable && totals([]).capacity == 0)
    print("PASS: windows summed independently; cooldown preserves quota; disabled excluded; unknown marked partial.")
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = QuotaBar()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
