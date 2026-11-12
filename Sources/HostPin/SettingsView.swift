import AppKit
import HostPinCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case interface = "界面设置"
        case performance = "性能设置"
        case catalog = "规则来源"
        case backup = "备份设置"
        case advanced = "高级设置"
        case about = "关于"

        var id: Self { self }
        var label: String { localizedText(rawValue) }
        var symbol: String {
            switch self {
            case .interface: return "macwindow"
            case .performance: return "speedometer"
            case .catalog: return "cloud"
            case .backup: return "archivebox"
            case .advanced: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var section = Section.interface
    @State private var reset = false
    @State private var catalogAddress = ""
    @State private var importingCatalog = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        HStack(spacing: 8) {
                            Label(item.label, systemImage: item.symbol)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .foregroundStyle(section == item ? Theme.accent : .primary)
                        .modifier(GlassControlSurface(tint: section == item ? Theme.tint.opacity(0.22) : nil))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }
            .modifier(GlassControls())
            .padding(10)
            .frame(width: 154)
            .background(NativeBackdrop(material: .sidebar).allowsHitTesting(false))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.label).font(.title2.weight(.semibold)).padding(.bottom, 6)
                switch section {
                case .interface: interfaceSettings
                case .performance: performanceSettings
                case .catalog: catalogSettings
                case .backup: backupSettings
                case .advanced: advancedSettings
                case .about: aboutSettings
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface)
        }
        .frame(width: 678, height: 349)
        .background(NativeBackdrop(material: .underWindowBackground).allowsHitTesting(false))
        .tint(Theme.tint)
        .buttonStyle(WorkButtonStyle())
        .confirmationDialog(L("重置所有设置"), isPresented: $reset) {
            Button(L("重置设置"), role: .destructive, action: model.resetPreferences)
        } message: { Text(L("将语言、外观及其他设置恢复为默认值。")) }
        .sheet(item: previewBinding(model, fromSettings: true)) { WriteReview(model: model, change: $0) }
        .fileImporter(isPresented: $importingCatalog, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                model.importCatalog(url, fromSettings: true)
            } catch { model.settingsWarning = error.localizedDescription }
        }
        .alert("HostPin", isPresented: Binding(
            get: { model.settingsWarning != nil },
            set: { if !$0 { model.settingsWarning = nil } }
        )) { Button(L("好")) { model.settingsWarning = nil } } message: {
            Text(localizedText(model.settingsWarning ?? ""))
        }
    }

    private var interfaceSettings: some View {
        VStack(spacing: 0) {
            preference(L("语言"), L("选择界面使用的语言。")) {
                PreferencePicker(title: L("语言"), value: $model.preferences.english,
                                 options: [false, true]) { $0 ? "English" : "简体中文" }
            }
            Divider()
            preference(L("外观"), L("跟随 macOS 或固定浅色、深色。")) {
                PreferencePicker(title: L("外观"), value: $model.preferences.appearance,
                                 options: HostPinPreferences.Appearance.allCases) { appearance in
                    switch appearance {
                    case .system: return L("跟随系统")
                    case .light: return L("浅色")
                    case .dark: return L("深色")
                    }
                }
            }
            Divider()
            preference(L("菜单图标大小"), L("调整规则列表和当前规则的图标。")) {
                PreferencePicker(title: L("菜单图标大小"), value: $model.preferences.iconSize,
                                 options: [32, 16]) { $0 == 32 ? L("大 · 32 × 32") : L("小 · 16 × 16") }
            }
        }
    }

    private var performanceSettings: some View {
        VStack(spacing: 0) {
            preference(L("延迟检测模式"), L("应用于单条规则和批量优化的延迟检测。")) {
                PreferencePicker(title: L("延迟检测模式"), value: $model.preferences.latency,
                                 options: LatencyMode.allCases.map(\.rawValue)) { $0 }
            }
            Divider()
            preference(L("批量阶段 1 并发数"), L("同时进行延迟检测和 TLS 验证的规则数。")) {
                PreferencePicker(title: L("批量阶段 1 并发数"), value: $model.preferences.phaseOne,
                                 options: Array(1...10)) { String($0) }
            }
            Divider()
            preference(L("批量阶段 2 并发数"), L("同时进行下载测速的规则数。")) {
                PreferencePicker(title: L("批量阶段 2 并发数"), value: $model.preferences.phaseTwo,
                                 options: Array(1...10)) { String($0) }
            }
            Divider()
            preference(L("DNS 服务器"), L("规则页进行 DNS 查询时使用。")) {
                PreferencePicker(title: L("DNS 服务器"), value: $model.preferences.dnsServer,
                                 options: ["223.5.5.5", "119.29.29.29", "1.1.1.1"]) { $0 }
            }
        }
    }

    private var backupSettings: some View {
        VStack(spacing: 0) {
            preference(L("自动备份 Hosts"), L("写入系统 Hosts 前创建备份。")) {
                Toggle(L("自动备份 Hosts"), isOn: $model.preferences.backupEnabled).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            preference(L("备份保留数量"), L("成功写入后保留最近的备份。")) {
                PreferencePicker(title: L("备份保留数量"), value: $model.preferences.backupRetention,
                                 options: Array(stride(from: 10, through: 100, by: 10))) { String($0) }
            }
            Divider()
            preference(L("备份目录"), L("在 Finder 查看备份，或选择一份备份进行还原。")) {
                HStack(spacing: 6) {
                    Button(L("打开目录")) { Task { await model.openBackupDirectory() } }
                    Button(L("从备份还原…"), action: chooseBackup)
                }
            }
        }
    }

    private var advancedSettings: some View {
        VStack(spacing: 0) {
            preference(L("清除所有 Hosts 规则"), L("预览移除 HostPin 和兼容原版标记的规则。")) {
                Button(L("清除规则…"), action: model.prepareClearAll).foregroundStyle(.red)
            }
            Divider()
            preference(L("重置所有设置"), L("将设置恢复为默认值。")) {
                Button(L("重置设置…")) { reset = true }.foregroundStyle(.red)
            }
        }
    }

    private var catalogSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L("规则库迁址时，输入新的 HTTPS 规则文件地址。留空可恢复默认来源。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("https://", text: $catalogAddress)
                    .accessibilityLabel(L("规则文件地址"))
                    .disabled(model.loading)
                Button(L("验证并切换")) {
                    Task { await model.changeCatalogSource(catalogAddress) }
                }
                .disabled(!model.canUpdateCatalog)
            }
            Text(model.preferences.catalogSource.map { L("当前首选来源：\($0.host ?? $0.absoluteString)") }
                 ?? L("当前首选来源：原作者默认地址"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                WorkStatus(text: localizedText(model.catalogStatus), inProgress: model.loading)
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button(L("刷新在线规则")) { Task { await model.refreshCatalog() } }
                    .disabled(!model.canUpdateCatalog)
            }
            if let date = model.catalogUpdatedAt {
                let saved = date.formatted(date: .abbreviated, time: .shortened)
                Text(L("快照时间：\(saved)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let origin = model.catalogOrigin?.host {
                Text(L("本次下载来源：\(origin)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(L("导入规则文件…")) { importingCatalog = true }
                    .disabled(!model.canUpdateCatalog)
                Button(L("导出规则快照…"), action: saveCatalogSnapshot)
                    .disabled(!model.canExportCatalog)
            }
        }
        .padding(.top, 7)
        .onAppear { catalogAddress = model.preferences.catalogSource?.absoluteString ?? "" }
        .onChange(of: model.preferences.catalogSource) { _, url in catalogAddress = url?.absoluteString ?? "" }
    }

    private func saveCatalogSnapshot() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "HostPin-rules.ini"
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .data]
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { model.exportCatalog(to: url) }
        }
    }

    private var aboutSettings: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("HostPin 定址").font(.headline)
                    if let version { Text(L("版本 \(version)")).foregroundStyle(.secondary) }
                    Text(L("HostPin 开发：ZyonLiu"))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("原版与鸣谢")).font(.headline)
                Text("UsbEAm Hosts Editor 5.0.1")
                Text(L("原作者：羽翼城 | Dogfight360"))
                Text(L("感谢原作者开发 UsbEAm Hosts Editor 并提供在线规则。"))
                    .foregroundStyle(.secondary)
                Link(L("查看原版发布页"), destination: URL(string: "https://www.dogfight360.com/blog/18627/")!)
            }
        }
        .font(.callout)
        .padding(.top, 8)
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.directoryURL = HelperConfiguration.backupDirectory
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("预览还原")
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { model.prepareRestore(from: url) }
            }
        }
    }

    private func preference<Control: View>(_ title: String, _ detail: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            control()
        }
        .frame(minHeight: 51)
        .padding(.vertical, 3)
    }
}

private struct PreferencePicker<Value: Hashable>: View {
    let title: String
    @Binding var value: Value
    let options: [Value]
    let label: (Value) -> String
    @State private var expanded = false
    @FocusState private var focused: Value?

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack {
                Text(label(value)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(width: 136, height: 29)
            .modifier(GlassControlSurface())
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(expanded ? Theme.accent : .primary.opacity(0.16)) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(label(value))
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                value = option
                                expanded = false
                            } label: {
                                HStack {
                                    Text(label(option))
                                    Spacer()
                                    if value == option { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                                }
                                .foregroundStyle(value == option ? Theme.accent : .primary)
                                .padding(.horizontal, 8)
                                .frame(height: 27)
                                .background(value == option || focused == option ? Theme.accent.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focused, equals: option)
                            .accessibilityAddTraits(value == option ? .isSelected : [])
                            .id(option)
                        }
                    }
                }
                .frame(width: 145, height: CGFloat(min(options.count, 7) * 29))
                .onAppear {
                    focused = value
                    scroll.scrollTo(value, anchor: .center)
                }
                .onKeyPress(.downArrow) {
                    moveFocus(1, scroll: scroll)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveFocus(-1, scroll: scroll)
                    return .handled
                }
                .onKeyPress(.return) {
                    if let focused { value = focused }
                    expanded = false
                    return .handled
                }
            }
            .padding(5)
        }
    }

    private func moveFocus(_ delta: Int, scroll: ScrollViewProxy) {
        guard let index = options.firstIndex(of: focused ?? value), !options.isEmpty else { return }
        let option = options[min(options.count - 1, max(0, index + delta))]
        focused = option
        scroll.scrollTo(option)
    }
}
