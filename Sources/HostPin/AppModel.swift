import AppKit
import Foundation
import HostPinCore

struct SavedGroup: Codable, Identifiable {
    let id: UUID
    let name: String
    let ruleIDs: [String]
}

struct BatchResult: Identifiable {
    let rule: Rule
    let candidate: Candidate?
    var id: String { rule.id }
}

struct WritePreview: Identifiable {
    let id = UUID()
    let title: String
    let expected: String
    let proposed: String
    var fromSettings = false
    var successNotice: String? = nil
}

@MainActor
final class AppModel: ObservableObject {
    let editorSession = HostsEditorSession()
    @Published var rules: [Rule] = []
    @Published var preferences = HostPinPreferences.load() {
        didSet {
            preferences.save()
            if preferences.appearance != oldValue.appearance { applyAppearance() }
        }
    }
    @Published var selectedRuleID: String? {
        didSet {
            guard selectedRuleID != oldValue else { return }
            operation?.cancel()
            operationID = nil
            phase = nil
            candidates = selectedRule?.addresses.map(Candidate.init) ?? []
            selectedIP = nil
        }
    }
    @Published var candidates: [Candidate] = []
    @Published var selectedIP: String?
    @Published var catalogStatus = "正在准备规则库"
    @Published private(set) var catalogUpdatedAt: Date?
    @Published private(set) var catalogOrigin: URL?
    @Published var loading = false
    @Published var phase: String?
    @Published var testedCount = 0
    @Published var hosts = ""
    @Published var draft = ""
    @Published var hostsStatus = ""
    @Published private(set) var settingsHostsRefreshID: UUID?
    @Published var warning: String?
    @Published var writeNotice: String?
    @Published var settingsWarning: String?
    @Published var preview: WritePreview?
    @Published var writing = false
    @Published var writerEnabled = false
    @Published private(set) var batchQueue: Set<String> = []
    @Published var batchIDs: Set<String> = []
    @Published var batchResults: [BatchResult] = []
    @Published private(set) var batchPhases: [Rule.ID: String] = [:]
    @Published private(set) var batchRunning = false
    @Published var groups: [SavedGroup] = []
    @Published private(set) var activeGroupID: UUID?

    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var started = false
    private var catalogData: Data?
    private static let cache = URL.applicationSupportDirectory.appendingPathComponent("HostPin/rules.ini")
    private static let groupKey = "savedRuleGroups"
    private static let defaultGroupKey = "defaultRuleGroup"

    var selectedRule: Rule? { rules.first { $0.id == selectedRuleID } }
    var batchRules: [Rule] { rules.filter { batchQueue.contains($0.id) && batchIDs.contains($0.id) } }
    var latencyMode: LatencyMode { LatencyMode(rawValue: preferences.latency) ?? .tcp }
    var canUpdateCatalog: Bool { !loading && phase == nil && !writing }
    var canExportCatalog: Bool { catalogData != nil }

    private var defaultCatalogSources: [URL] { [RuleCatalog.source, RuleCatalog.mirror] }

    func start() async {
        applyAppearance()
        guard !started else { return }
        started = true
        syncWriterStatus()
        if let data = UserDefaults.standard.data(forKey: Self.groupKey),
           let saved = try? JSONDecoder().decode([SavedGroup].self, from: data) { groups = saved }
        loadGroup(nil)
        reloadHosts()
        if let cache = try? LimitedFile.read(Self.cache, maximumSize: RuleCatalog.maxSize), let cached = try? RuleCatalog.parse(cache) {
            catalogData = cache
            catalogUpdatedAt = try? Self.cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            install(cached)
            catalogStatus = "本地缓存 · \(cached.count) 条规则"
        }
        await refreshCatalog()
    }

    func refreshCatalog() async {
        let sources = preferences.catalogSource.map { [$0] } ?? defaultCatalogSources
        _ = await updateCatalog(from: sources, changingSource: false)
    }

    func changeCatalogSource(_ input: String) async {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = RuleCatalog.httpsSource(value)
        guard value.isEmpty || source != nil else {
            settingsWarning = "请输入有效的 HTTPS 规则文件地址。"
            return
        }
        let sources = source.map { [$0] } ?? defaultCatalogSources
        if await updateCatalog(from: sources, changingSource: true) {
            preferences.catalogSource = source
        }
    }

    private func updateCatalog(from sources: [URL], changingSource: Bool) async -> Bool {
        guard canUpdateCatalog else { return false }
        let feedbackDeadline = ContinuousClock.now.advanced(by: WorkMotion.feedback)
        loading = true
        defer { loading = false }
        for (index, source) in sources.enumerated() {
            catalogStatus = index == 0 ? "正在下载规则…" : "正在尝试备用源…"
            do {
                let (data, origin) = try await RuleCatalog.download(from: source)
                catalogStatus = "正在校验规则…"
                let incoming = try await Task.detached(priority: .userInitiated) {
                    try RuleCatalog.parse(data)
                }.value
                catalogStatus = "正在更新规则…"
                try? await Task.sleep(until: feedbackDeadline, clock: .continuous)
                guard !Task.isCancelled, phase == nil, !writing else { break }
                try storeCatalog(data, rules: incoming, origin: origin)
                catalogStatus = "已更新 · \(rules.count) 条"
                return true
            } catch {
                if Task.isCancelled { break }
            }
        }
        try? await Task.sleep(until: feedbackDeadline, clock: .continuous)
        catalogStatus = rules.isEmpty ? "在线规则加载失败" : "使用本地快照 · \(rules.count) 条"
        if changingSource && !Task.isCancelled {
            settingsWarning = "无法切换规则源。请确认地址可访问且提供兼容的 UsbEAm 规则文件。"
        }
        return false
    }

    func importCatalog(_ url: URL, fromSettings: Bool = false) {
        guard canUpdateCatalog else { return }
        do {
            let data = try LimitedFile.read(url, maximumSize: RuleCatalog.maxSize)
            let imported = try RuleCatalog.parse(data)
            try storeCatalog(data, rules: imported, origin: nil)
            catalogStatus = "已导入 · \(rules.count) 条规则"
        } catch {
            if fromSettings { settingsWarning = error.localizedDescription }
            else { warning = error.localizedDescription }
        }
    }

    func exportCatalog(to url: URL) {
        guard let catalogData else { return }
        do { try catalogData.write(to: url, options: .atomic) }
        catch { settingsWarning = error.localizedDescription }
    }

    private func storeCatalog(_ data: Data, rules: [Rule], origin: URL?) throws {
        try FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.cache, options: .atomic)
        catalogData = data
        catalogOrigin = origin
        catalogUpdatedAt = Date()
        install(rules)
    }

    private func install(_ incoming: [Rule]) {
        if rules == incoming { return }
        let oldRule = selectedRule
        rules = incoming
        let rulesByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        batchResults.removeAll { rulesByID[$0.id] != $0.rule }
        if selectedRule == nil { selectedRuleID = incoming.first?.id }
        else if selectedRule != oldRule {
            cancel()
            candidates = selectedRule?.addresses.map(Candidate.init) ?? []
            selectedIP = nil
        }
    }

    func measure() {
        guard let rule = selectedRule, !candidates.isEmpty, phase == nil, !writing else { return }
        let inputs = candidates
        let mode = latencyMode
        begin("检测延迟") { model, id in
            let results = await NetworkProbe.latencies(inputs, port: rule.port, mode: mode) { [weak model] candidate in
                await model?.received(candidate, for: id)
            }
            guard model.operationID == id else { return }
            model.candidates = results.sorted { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }
        }
    }

    private func received(_ candidate: Candidate, for id: UUID) {
        guard operationID == id else { return }
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) { candidates[index] = candidate }
        testedCount += 1
    }

    func measureSpeed() {
        guard let rule = selectedRule, let selectedIP, phase == nil, !writing else { return }
        begin("测试下载速度") { model, id in
            let speed = await NetworkProbe.speed(selectedIP, for: rule)
            guard model.operationID == id else { return }
            if let index = model.candidates.firstIndex(where: { $0.id == selectedIP }) { model.candidates[index].speed = speed }
            if speed == nil { model.warning = "该 IP 未返回有效的下载样本。" }
        }
    }

    func optimize() {
        guard let rule = selectedRule, !candidates.isEmpty, phase == nil, !writing else { return }
        let inputs = candidates.map { Candidate(address: $0.address) }
        let mode = latencyMode
        candidates = inputs
        begin("检测延迟") { model, id in
            let result = await NetworkProbe.optimize(rule, candidates: inputs, mode: mode) { [weak model] candidate in
                await model?.received(candidate, for: id)
            } onPhase: { [weak model] phase in
                await model?.setPhase(phase, for: id)
            }
            guard model.operationID == id else { return }
            model.candidates = result.candidates.sorted { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }
            if let best = result.best {
                model.selectedIP = best.id
                let value = best.downloadMbps.map { "\($0.formatted(.number.precision(.fractionLength(0)))) Mbps" }
                    ?? best.latency.map { String(format: "%.1f ms", $0) } ?? "—"
                await model.applyChanges([(rule, best.address)], title: "应用自动优化结果",
                                         notice: L("已应用 \(best.address)（\(value)）"))
            } else {
                model.warning = "没有找到通过连接和所需验证的候选 IP。"
            }
        }
    }

    func resolveDNS() {
        guard let rule = selectedRule, phase == nil, !writing else { return }
        let server = preferences.dnsServer
        begin("查询 DNS") { model, id in
            let addresses = await NetworkProbe.dns(rule, server: server)
            guard model.operationID == id else { return }
            model.selectedIP = nil
            model.candidates = addresses.map(Candidate.init)
            if addresses.isEmpty { model.warning = "DNS 查询未返回有效 IP。" }
        }
    }

    func runBatch() {
        let rules = batchRules
        guard !rules.isEmpty, phase == nil, !writing else { return }
        let mode = latencyMode
        let stageOne = preferences.phaseOne
        let stageTwo = preferences.phaseTwo
        batchResults = []
        begin("准备批量任务") { model, id in
            await NetworkProbe.optimizeBatch(rules, screeningLimit: stageOne, downloadLimit: stageTwo, mode: mode) {
                [weak model] rule, phase in
                await model?.updateBatchPhase(phase, ruleID: rule.id, operationID: id)
            } onResult: { [weak model] rule, candidate in
                await model?.finishBatchRule(rule, candidate: candidate, operationID: id)
            }
            guard model.operationID == id, !Task.isCancelled else { return }
            if model.batchResults.contains(where: { $0.candidate != nil }) { await model.applyBatch() }
        }
        batchRunning = true
    }

    private func updateBatchPhase(_ phase: String, ruleID: Rule.ID, operationID: UUID) {
        guard self.operationID == operationID else { return }
        batchPhases[ruleID] = phase
    }

    private func finishBatchRule(_ rule: Rule, candidate: Candidate?, operationID: UUID) {
        guard self.operationID == operationID else { return }
        batchResults.append(BatchResult(rule: rule, candidate: candidate))
        batchPhases.removeValue(forKey: rule.id)
    }

    func applyBatch() async {
        let results = Dictionary(uniqueKeysWithValues: batchResults.map { ($0.id, $0) })
        let changes = batchRules.compactMap { rule in
            results[rule.id]?.candidate.map { (rule, $0.address) }
        }
        guard !changes.isEmpty else { return }
        await applyChanges(changes, title: "应用批量优化结果", notice: L("已应用 \(changes.count) 条批量结果。"))
    }

    func addToBatch(_ rule: Rule) {
        guard !batchRunning else { return }
        batchQueue.insert(rule.id)
        batchIDs.insert(rule.id)
    }

    func removeFromBatch(_ ids: Set<String>) {
        guard !batchRunning else { return }
        batchQueue.subtract(ids)
        batchIDs.subtract(ids)
        batchResults.removeAll { ids.contains($0.id) }
    }

    func loadGroup(_ id: UUID?) {
        guard !batchRunning else { return }
        let ids: [String]
        if let id {
            guard let group = groups.first(where: { $0.id == id }) else { return }
            ids = group.ruleIDs
        } else {
            ids = UserDefaults.standard.stringArray(forKey: Self.defaultGroupKey) ?? []
        }
        activeGroupID = id
        batchQueue = Set(ids)
        batchIDs = batchQueue
        batchResults = []
    }

    func saveActiveGroup() {
        guard !batchRunning else { return }
        if let id = activeGroupID, let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index] = SavedGroup(id: id, name: groups[index].name, ruleIDs: batchQueue.sorted())
            persistGroups()
        } else {
            UserDefaults.standard.set(batchQueue.sorted(), forKey: Self.defaultGroupKey)
        }
    }

    func createGroup(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !batchRunning, !name.isEmpty else { return }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            warning = L("已有同名分组。")
            return
        }
        let group = SavedGroup(id: UUID(), name: name, ruleIDs: [])
        groups.append(group)
        persistGroups()
        loadGroup(group.id)
    }

    func deleteGroup(_ id: UUID) {
        guard !batchRunning else { return }
        groups.removeAll { $0.id == id }
        persistGroups()
        if activeGroupID == id { loadGroup(nil) }
    }

    private func persistGroups() {
        if let data = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(data, forKey: Self.groupKey) }
    }

    private func begin(_ title: String, action: @escaping @MainActor (AppModel, UUID) async -> Void) {
        cancel()
        let id = UUID()
        operationID = id
        phase = title
        testedCount = 0
        operation = Task { [weak self] in
            guard let self else { return }
            await action(self, id)
            if self.operationID == id {
                self.phase = nil
                self.operationID = nil
                self.operation = nil
                self.batchRunning = false
            }
        }
    }

    private func setPhase(_ phase: String, for id: UUID) {
        if operationID == id { self.phase = phase }
    }

    func cancel() {
        guard !writing else { return }
        operation?.cancel()
        operation = nil
        operationID = nil
        phase = nil
        batchRunning = false
        batchPhases.removeAll()
    }

    func reloadHosts(automatically: Bool = false) {
        do {
            let current = try HostsDocument.read()
            if automatically && draft != hosts {
                hostsStatus = current == hosts ? "有未保存的更改 · 草稿已保留" : "系统 Hosts 已变化 · 草稿已保留"
                return
            }
            hosts = current
            draft = current
            hostsStatus = automatically ? "已自动刷新 Hosts" : "已重新加载 Hosts"
        } catch {
            hostsStatus = "读取 Hosts 失败"
            warning = error.localizedDescription
        }
    }

    func ruleName(_ rule: Rule) -> String { preferences.english ? rule.englishName : rule.name }

    func groupName(_ group: String) -> String {
        let names = group.components(separatedBy: " - ")
        return (preferences.english ? names.first : names.last) ?? group
    }

    func prepareClearAll() {
        do {
            let current = try HostsDocument.read()
            let proposed = HostsDocument.removingManagedMappings(from: current)
            guard proposed != current else { settingsWarning = "没有需要清除的规则。"; return }
            preview = WritePreview(title: "清除工具添加的 Hosts 规则", expected: current, proposed: proposed, fromSettings: true)
        } catch { settingsWarning = error.localizedDescription }
    }

    func prepareRestore(from url: URL) {
        do {
            let current = try HostsDocument.read()
            let restored = try HostsDocument.read(url)
            guard restored != current else { settingsWarning = "备份内容与当前 Hosts 相同。"; return }
            preview = WritePreview(title: "从备份还原 Hosts", expected: current, proposed: restored, fromSettings: true)
        } catch { settingsWarning = error.localizedDescription }
    }

    func openBackupDirectory() async {
        do {
            let url = HelperConfiguration.backupDirectory
            if !FileManager.default.fileExists(atPath: url.path) { try await WriterClient.prepareBackupDirectory() }
            if !NSWorkspace.shared.open(url) { settingsWarning = "无法打开备份目录。" }
        } catch { settingsWarning = error.localizedDescription }
    }

    func resetPreferences() { preferences = HostPinPreferences() }

    private func applyAppearance() { NSApp.appearance = preferences.appearance.appKitAppearance }

    func saveDraft() async {
        guard draft != hosts, phase == nil else { return }
        await submit(WritePreview(title: "保存 Hosts 文件", expected: hosts, proposed: draft))
    }

    func applySelection(_ rule: Rule, address: String) {
        guard phase == nil, !writing else { return }
        begin("应用选中…") { model, id in
            let verified = rule.certificateNames.isEmpty ? true : await NetworkProbe.verify(address, for: rule)
            guard model.operationID == id, !Task.isCancelled else { return }
            let warning = verified ? nil : L("选中地址未通过 TLS 验证。确认后仍可应用。")
            await model.applyChanges([(rule, address)], title: L("应用 \(model.ruleName(rule))"),
                                     notice: L("已应用 \(address)。"), reviewWarning: warning)
        }
    }

    func applyChanges(_ changes: [(rule: Rule, address: String?)], title: String,
                      notice: String? = nil, reviewWarning: String? = nil) async {
        guard !writing else { return }
        do {
            let current = try HostsDocument.read()
            let proposed = try HostsDocument.applying(changes, to: current)
            guard current != proposed else { warning = "Hosts 文件没有需要应用的更改。"; return }
            let change = WritePreview(title: title, expected: current, proposed: proposed, successNotice: notice)
            if let reviewWarning {
                warning = reviewWarning
                preview = change
            } else {
                await submit(change)
            }
        } catch { warning = error.localizedDescription }
    }

    private func submit(_ change: WritePreview) async {
        guard !writing else { return }
        if writerEnabled {
            await confirm(change)
        } else {
            preview = change
        }
    }

    func syncWriterStatus() {
        Task { writerEnabled = await WriterClient.isEnabled() }
    }

    func enableWriter() {
        warning = nil
        Task {
            do {
                try await WriterClient.enable()
                writerEnabled = await WriterClient.isEnabled()
            } catch { warning = error.localizedDescription }
        }
    }

    func confirm(_ change: WritePreview) async {
        guard !writing else { return }
        writing = true
        warning = nil
        defer { writing = false }
        do {
            try await WriterClient.replace(change.proposed, expected: change.expected,
                                           backupEnabled: preferences.backupEnabled, backupRetention: preferences.backupRetention)
            preview = nil
            let keepDraft = draft != hosts && draft != change.proposed
            hosts = change.proposed
            if !keepDraft { draft = hosts }
            hostsStatus = "已保存 Hosts"
            if change.fromSettings { settingsHostsRefreshID = UUID() }
            writeNotice = change.successNotice
        } catch { warning = error.localizedDescription }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
