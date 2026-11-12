import AppKit
import HostPinCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct HostPinApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("HostPin", id: "main") {
            RootView(model: model)
                .frame(minWidth: 840, minHeight: 550)
                .task { await model.start() }
        }
        .defaultSize(width: 1060, height: 674)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu(L("规则")) {
                Button(L("刷新在线规则")) { Task { await model.refreshCatalog() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canUpdateCatalog)
                Button(L("检测延迟"), action: model.measure)
                    .disabled(model.phase != nil || model.candidates.isEmpty)
                Button(L("自动优化"), action: model.optimize)
                    .disabled(model.phase != nil || model.candidates.isEmpty)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case rules = "规则库"
    case batch = "批量处理"
    case hosts = "Hosts 编辑"

    var id: Self { self }
    var title: String { localizedText(rawValue) }
    var icon: String {
        switch self {
        case .rules: return "square.on.square"
        case .batch: return "checklist"
        case .hosts: return "doc.text"
        }
    }
}

enum Theme {
    static let accent = dynamic(light: (0.50, 0.31, 0.13), dark: (0.94, 0.77, 0.55))
    static let tint = dynamic(light: (0.52, 0.32, 0.16), dark: (0.89, 0.66, 0.42))
    static let canvas = dynamic(light: (0.97, 0.96, 0.94), dark: (0.13, 0.12, 0.11))
    static let surface = dynamic(light: (1.00, 0.99, 0.97), dark: (0.17, 0.16, 0.15))
    static let sidebar = dynamic(light: (0.94, 0.92, 0.89), dark: (0.16, 0.15, 0.14))
    static let onAccent = dynamic(light: (1.0, 0.98, 0.95), dark: (0.20, 0.13, 0.08))

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

private struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Page = .rules
    @State private var query = ""
    @State private var importing = false
    @State private var collapsedGroups: Set<String> = []
    @State private var ruleReveal: RuleReveal?
    @AppStorage("ruleSidebarWidth") private var sidebarWidth: Double = 240
    @State private var sidebarDrag: CGFloat = 0
    @State private var dividerHovered = false

    private struct RuleReveal: Equatable {
        let id: String
        let request = UUID()
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            switch page {
            case .rules:
                catalogBar
                Divider()
                ruleWorkspace
            case .batch:
                BatchView(model: model).padding(23).background(Theme.canvas)
            case .hosts:
                HostsView(model: model).padding(23).background(Theme.canvas)
            }
            Divider()
            statusBar
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(NativeBackdrop(material: .underWindowBackground).allowsHitTesting(false))
        .tint(Theme.tint)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                model.importCatalog(url)
            } catch { model.warning = error.localizedDescription }
        }
        .sheet(item: previewBinding(model, fromSettings: false)) { WriteReview(model: model, change: $0) }
        .alert("HostPin", isPresented: Binding(
            get: { (model.warning != nil || model.writeNotice != nil) && model.preview == nil },
            set: { if !$0 { model.warning = nil; model.writeNotice = nil } }
        )) {
            Button(L("好")) { model.warning = nil; model.writeNotice = nil }
        } message: { Text(localizedText(model.warning ?? model.writeNotice ?? "")) }
        .onChange(of: page) { _, value in
            if value != .rules {
                dividerHovered = false
                sidebarDrag = 0
            }
        }
        .onChange(of: scenePhase) { _, value in if value == .active { model.syncWriterStatus() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.syncWriterStatus()
        }
    }

    private var titleBar: some View {
        ZStack {
            HStack {
                WindowBrand()
                    .padding(.leading, 78)
                    // The native traffic lights center at 16 pt from the top.
                    // This custom row centers at 19 pt inside the 44 pt header.
                    .offset(y: -3)
                Spacer()
                Menu {
                    Button(L("导入规则文件…")) { importing = true }.disabled(!model.canUpdateCatalog)
                    SettingsLink { Text(L("设置…")) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 29, height: 30)
                        .modifier(GlassControlSurface())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("更多选项"))
                .accessibilityLabel(L("更多选项"))
                .padding(.trailing, 15)
            }
            HStack(spacing: 5) {
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .frame(height: 31)
                            .foregroundStyle(page == item ? Theme.accent : .primary)
                            .modifier(GlassControlSurface(tint: page == item ? Theme.tint.opacity(0.22) : nil))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .contextMenu {
                        if item == .rules {
                            RuleCategoryMenu(model: model, action: openRule)
                        } else if item == .batch {
                            RuleCategoryMenu(model: model) { rule in
                                model.addToBatch(rule)
                                page = .batch
                            }
                        }
                    }
                }
            }
            .modifier(GlassControls())
        }
        .padding(.bottom, 6)
        .frame(height: 44)
        .background(WindowDragArea())
        .background(.bar)
    }

    private func openRule(_ rule: Rule) {
        guard model.phase == nil else { return }
        query = ""
        collapsedGroups.remove(rule.group)
        model.selectedRuleID = rule.id
        ruleReveal = RuleReveal(id: rule.id)
        page = .rules
    }

    private var ruleWorkspace: some View {
        GeometryReader { geometry in
            let minimum: CGFloat = 168
            let maximum = max(minimum, min(360, geometry.size.width - 555 - 9))
            let clamp: (CGFloat) -> CGFloat = { min(maximum, max(minimum, $0)) }
            let baseWidth = clamp(sidebarWidth)
            let resizing = dividerHovered || sidebarDrag != 0
            HStack(spacing: 0) {
                rulePicker.frame(width: clamp(baseWidth + sidebarDrag))
                Rectangle()
                    .fill(.clear)
                    .overlay {
                        Rectangle().fill(resizing ? Theme.accent.opacity(0.65) : .primary.opacity(0.13))
                            .frame(width: resizing ? 2 : 1)
                    }
                    .frame(width: 9)
                    .overlay {
                        SidebarResizeArea { hovered in
                            dividerHovered = hovered
                        } onDrag: { offset, finished in
                            if finished {
                                sidebarWidth = clamp(baseWidth + offset)
                                sidebarDrag = 0
                            } else {
                                sidebarDrag = offset
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("调整规则侧栏宽度"))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: sidebarWidth = clamp(baseWidth + 16)
                        case .decrement: sidebarWidth = clamp(baseWidth - 16)
                        @unknown default: break
                        }
                    }
                RulesView(model: model, openRule: openRule)
                    .padding(22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas)
            }
        }
    }

    private var catalogBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 33, height: 33)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("在线规则")).font(.headline)
                WorkStatus(text: localizedText(model.catalogStatus), inProgress: model.loading)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .frame(height: 14, alignment: .leading)
                    .help(localizedText(model.catalogStatus))
            }
            .frame(width: 125, alignment: .leading)
            .padding(.trailing, 8)
            SearchField(placeholder: L("搜索规则名或域名"), text: $query)
                .frame(maxWidth: 350)
            Button { Task { await model.refreshCatalog() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
            }
            .buttonStyle(WorkButtonStyle())
            .help(L("刷新在线规则"))
            .accessibilityLabel(L("刷新在线规则"))
            .disabled(!model.canUpdateCatalog)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var rulePicker: some View {
        let results = model.rules.filter { $0.matches(query) }
        let sections = Dictionary(grouping: results, by: \.group)
        return Group {
            if results.isEmpty {
                Text(model.loading ? L("正在加载规则…") : query.isEmpty ? L("暂无规则") : L("没有匹配的规则"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List(selection: $model.selectedRuleID) {
                        ForEach(unique(results.map(\.group)), id: \.self) { group in
                            Section(isExpanded: groupExpansion(group)) {
                                ForEach(sections[group] ?? []) { rule in
                                    HStack(spacing: 7) {
                                        RuleMark(size: model.preferences.iconSize, group: rule.group)
                                        Text(model.ruleName(rule)).lineLimit(1)
                                    }
                                    .help(model.ruleName(rule))
                                    .contextMenu {
                                        Button(L("添加到批量处理")) { model.addToBatch(rule) }
                                        Divider()
                                        RuleCategoryMenu(model: model, action: openRule)
                                    }
                                    .tag(rule.id)
                                    .id(rule.id)
                                }
                            } header: {
                                Text(model.groupName(group)).textCase(nil).lineLimit(1)
                                    .foregroundStyle(.secondary).help(group)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .disabled(model.phase != nil)
                    .task(id: ruleReveal) {
                        guard let reveal = ruleReveal else { return }
                        await Task.yield()
                        guard !Task.isCancelled, model.selectedRuleID == reveal.id else { return }
                        scroll.scrollTo(reveal.id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativeBackdrop(material: .sidebar).allowsHitTesting(false))
    }

    private func groupExpansion(_ group: String) -> Binding<Bool> {
        Binding(get: { !collapsedGroups.contains(group) }, set: { expanded in
            if expanded { collapsedGroups.remove(group) }
            else { collapsedGroups.insert(group) }
        })
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Button(action: model.enableWriter) {
                Label(model.writerEnabled ? L("Hosts 写入已启用") : L("启用 Hosts 写入"),
                      systemImage: model.writerEnabled ? "lock.open" : "lock")
            }
            .buttonStyle(.plain)
            .disabled(model.writerEnabled)
            Spacer()
            if let phase = model.phase, !model.batchRunning, page != .rules {
                WorkStatus(text: localizedText(phase), inProgress: true)
                if model.testedCount > 0 { Text("\(model.testedCount)/\(model.candidates.count)").monospacedDigit() }
                Button(L("停止"), action: model.cancel).controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private struct SidebarResizeArea: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onDrag: (_ offset: CGFloat, _ finished: Bool) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView() }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
    }

    final class ResizeView: NSView {
        var onHover: ((Bool) -> Void)?
        var onDrag: ((CGFloat, Bool) -> Void)?
        private var hoverArea: NSTrackingArea?
        private var dragOrigin: CGFloat?

        private var resizeCursor: NSCursor {
            if #available(macOS 15, *) { return .columnResize }
            return .resizeLeftRight
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
            resizeCursor.set()
        }

        override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
        override func mouseMoved(with event: NSEvent) { resizeCursor.set() }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow.x
            resizeCursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            resizeCursor.set()
            onDrag?(event.locationInWindow.x - dragOrigin, false)
        }

        override func mouseUp(with event: NSEvent) {
            guard let dragOrigin else { return }
            self.dragOrigin = nil
            onDrag?(event.locationInWindow.x - dragOrigin, true)
        }
    }
}

private struct RuleCategoryMenu: View {
    @ObservedObject var model: AppModel
    let action: (Rule) -> Void

    var body: some View {
        let sections = Dictionary(grouping: model.rules, by: \.group)
        if sections.isEmpty { Text(L("暂无规则")) }
        ForEach(unique(model.rules.map(\.group)), id: \.self) { group in
            Menu(model.groupName(group)) {
                ForEach(sections[group] ?? []) { rule in
                    Button(model.ruleName(rule)) { action(rule) }
                }
            }
            .disabled(model.phase != nil)
        }
    }
}

enum WorkMotion {
    static let feedback: Duration = .milliseconds(650)
    static let disclosure = Animation.easeOut(duration: 0.18)
}

struct WorkStatus: View {
    let text: String
    let inProgress: Bool
    var showsSeparator = false

    var body: some View {
        HStack(spacing: 7) {
            if inProgress {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else if showsSeparator {
                Text("·")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(text).lineLimit(1)
        }
    }
}

struct WorkButtonStyle: ButtonStyle {
    var prominent = false
    var quietAccent = false

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, prominent: prominent, quietAccent: quietAccent, pressed: configuration.isPressed)
    }

    private struct Face<Content: View>: View {
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        let label: Content
        let prominent: Bool
        let quietAccent: Bool
        let pressed: Bool

        var body: some View {
            label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 30)
                .foregroundStyle(!enabled ? Color.secondary
                                 : prominent ? Theme.onAccent : quietAccent ? Theme.accent : .primary)
                .modifier(GlassControlSurface(tint: prominent && enabled ? Theme.accent
                                              : quietAccent ? Theme.tint.opacity(0.22) : nil))
                .overlay {
                    if enabled && (pressed || hovered) {
                        RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(pressed ? 0.12 : 0.06))
                    }
                }
                .opacity(enabled ? 1 : 0.52)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

private struct WindowBrand: View {
    @Environment(\.colorScheme) private var scheme
    private static let artwork = Bundle.main.url(forResource: "HostPin", withExtension: "icns").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        HStack(spacing: 7) {
            if let artwork = Self.artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).frame(width: 23, height: 23)
                    .brightness(scheme == .dark ? 0.035 : -0.045)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("HostPin").font(.system(size: 13, weight: .semibold))
                Text("定址")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.35)
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

private struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var controlHeight: CGFloat = 31
    var focusRequest = 0
    var symbol = "magnifyingglass"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("清除搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: controlHeight)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accent : .primary.opacity(0.13)) }
        .task(id: focusRequest) {
            if focusRequest > 0 { focused = true }
        }
    }
}

private struct RuleMark: View {
    let size: Int
    let group: String

    var body: some View {
        let side: CGFloat = size == 16 ? 16 : 32
        Image(systemName: group.lowercased().contains("cdn") ? "cloud" : "link")
            .font(.system(size: side * 0.48, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: side, height: side)
            .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: side * 0.23))
            .accessibilityHidden(true)
    }
}

private struct WorkHeader<Trailing: View>: View {
    let section: String
    let title: String
    let subtitle: String
    var ruleMark: RuleMark? = nil
    var status: String? = nil
    var statusInProgress = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if !section.isEmpty {
                    Text(section).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                }
                HStack(spacing: 8) {
                    ruleMark
                    Text(title)
                        .font(.system(size: 29, weight: .semibold))
                        .tracking(-0.6)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                HStack(spacing: 7) {
                    Text(subtitle).foregroundStyle(.secondary).help(subtitle)
                    if let status, !status.isEmpty {
                        WorkStatus(text: status, inProgress: statusInProgress, showsSeparator: true)
                            .foregroundStyle(Theme.accent)
                            .help(status)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
                .modifier(GlassControls())
        }
        .padding(.bottom, 2)
    }
}

private struct WorkPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct RulesView: View {
    @ObservedObject var model: AppModel
    let openRule: (Rule) -> Void
    @State private var showsMappings = false
    @State private var sortOrder: [KeyPathComparator<Candidate>] = []

    var body: some View {
        if let rule = model.selectedRule {
            VStack(alignment: .leading, spacing: 17) {
                WorkHeader(section: model.groupName(rule.group), title: model.ruleName(rule),
                           subtitle: domainSummary(rule),
                           ruleMark: RuleMark(size: model.preferences.iconSize, group: rule.group)) {
                    Button {
                        showsMappings.toggle()
                    } label: { Label(L("域名与映射"), systemImage: "list.bullet.rectangle") }
                    .buttonStyle(WorkButtonStyle())
                    .popover(isPresented: $showsMappings, arrowEdge: .bottom) { mappingPopover(rule) }
                }
                WorkPanel {
                    candidateHeader(rule)
                    Divider()
                    candidateTable(rule)
                    Divider()
                    candidateActions(rule)
                }
            }
            .onChange(of: rule.id) { _, _ in sortOrder = [] }
        } else {
            ContentUnavailableView(L("选择一条规则"), systemImage: "square.stack",
                                   description: Text(L("从侧栏搜索域名或规则名，查看候选地址。")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func domainSummary(_ rule: Rule) -> String {
        guard let first = rule.domains.first else { return L("暂无域名") }
        return rule.domains.count > 1 ? first + L(" 等 \(rule.domains.count) 个域名") : first
    }

    private func candidateHeader(_ rule: Rule) -> some View {
        let running = model.phase != nil && !model.batchRunning
        return HStack(spacing: 8) {
            Text(L("候选地址")).font(.headline)
            Text(model.candidates.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.055), in: Capsule())
            if model.writing && !model.batchRunning {
                WorkStatus(text: L("正在保存 Hosts…"), inProgress: true)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            } else if let phase = model.phase, running {
                WorkStatus(text: phase == "检测延迟"
                           ? "\(localizedText(phase)) · \(model.testedCount)/\(model.candidates.count)"
                           : localizedText(phase), inProgress: true)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            Button(action: model.measure) {
                Label(L("检测延迟"), systemImage: "waveform.path")
            }
            .buttonStyle(WorkButtonStyle())
            .disabled(model.phase != nil || model.candidates.isEmpty)
            Button(action: model.measureSpeed) {
                Label(L("测试下载速度"), systemImage: "speedometer")
            }
            .buttonStyle(WorkButtonStyle())
            .disabled(model.phase != nil || model.selectedIP == nil || rule.downloadURL == nil)
            Button(action: running ? model.cancel : model.optimize) {
                ZStack {
                    Label(L("自动优化"), systemImage: "bolt")
                        .opacity(running ? 0 : 1)
                    Label(L("停止"), systemImage: "stop.fill")
                        .opacity(running ? 1 : 0)
                }
            }
            .buttonStyle(WorkButtonStyle(quietAccent: true))
            .accessibilityLabel(running ? L("停止") : L("自动优化"))
            .disabled(model.writing || (!running && (model.phase != nil || model.candidates.isEmpty)))
        }
        .controlSize(.regular)
        .padding(.horizontal, 15)
        .frame(height: 45)
        .modifier(GlassControls())
    }

    private func candidateTable(_ rule: Rule) -> some View {
        Group {
            if model.candidates.isEmpty {
                ContentUnavailableView(L("没有候选地址"), systemImage: "network",
                                       description: Text(L("通过 DNS 查询获取实时地址。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.candidates, selection: $model.selectedIP, sortOrder: $sortOrder) {
                    TableColumn(L("IP 地址"), value: \.address) { candidate in
                        Text(candidate.address)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1).help(candidate.address)
                    }.width(min: 145, ideal: 210)
                    TableColumn(L("延迟")) { candidate in
                        Text(candidate.latency.map { String(format: "%.1f ms", $0) } ?? (candidate.tested ? L("超时") : "—"))
                            .monospacedDigit()
                            .foregroundStyle(candidate.latency == nil ? .secondary : .primary)
                    }.width(min: 70, ideal: 102)
                    TableColumn(L("下载速度")) { candidate in
                        Text(candidate.downloadMbps.map { "\($0.formatted(.number.precision(.fractionLength(0)))) Mbps" } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(candidate.speed == nil ? .secondary : .primary)
                    }.width(min: 85, ideal: 118)
                    TableColumn("TLS") { candidate in
                        if candidate.tlsVerified { Label(L("通过"), systemImage: "checkmark.circle").foregroundStyle(Theme.accent) }
                        else { Text("—").foregroundStyle(.secondary) }
                    }.width(min: 62, ideal: 86)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: Candidate.ID.self) { ids in
                    RuleCategoryMenu(model: model, action: openRule)
                    Divider()
                    Button(L("添加到批量处理")) { model.addToBatch(rule) }.disabled(model.batchRunning)
                    if let ip = ids.first {
                        Button(L("复制 IP 地址")) { model.copy(ip) }
                        Button(L("复制选中映射")) { copyMapping(rule, ip: ip) }
                        Button(L("应用选中")) { model.applySelection(rule, address: ip) }
                            .disabled(model.phase != nil || model.writing)
                    }
                }
                .onChange(of: sortOrder) { _, order in
                    if !order.isEmpty { model.candidates.sort(using: order) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func candidateActions(_ rule: Rule) -> some View {
        HStack(spacing: 10) {
            if let ip = model.selectedIP {
                Label(ip, systemImage: "checkmark.circle")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
            } else {
                Text(L("选择一个地址以预览写入"))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                Task {
                    await model.applyChanges([(rule, nil)], title: L("清除 \(model.ruleName(rule)) 的 Hosts 映射"),
                                             notice: L("已清除当前规则映射。"))
                }
            } label: {
                Label(L("清除当前"), systemImage: "trash")
            }
            .help(L("清除当前规则映射…"))
            Button {
                if let ip = model.selectedIP { copyMapping(rule, ip: ip) }
            } label: { Label(L("复制映射"), systemImage: "doc.on.doc") }
            .disabled(model.selectedIP == nil)
            Button(action: model.resolveDNS) { Label(L("DNS 查询"), systemImage: "globe") }
            Button {
                if let ip = model.selectedIP { model.applySelection(rule, address: ip) }
            } label: { Label(L("应用选中"), systemImage: "checkmark") }
            .buttonStyle(WorkButtonStyle(prominent: true))
            .disabled(model.selectedIP == nil)
        }
        .buttonStyle(WorkButtonStyle())
        .padding(.horizontal, 15)
        .frame(height: 49)
        .disabled(model.phase != nil || model.writing)
        .modifier(GlassControls())
    }

    private func copyMapping(_ rule: Rule, ip: String) {
        model.copy(HostsDocument.copyLines(rule: rule, address: ip))
    }

    private func mappingPopover(_ rule: Rule) -> some View {
        let targets = Set(rule.domains)
        let mappings = HostsDocument.mappings(in: model.hosts).filter { !targets.isDisjoint(with: $0.domains) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("域名与映射")).font(.headline)
            if mappings.isEmpty { Text(L("当前 Hosts 文件中没有匹配的映射。")).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(rule.domains, id: \.self) { domain in
                        Text(domain).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        let active = mappings.filter { $0.domains.contains(domain) }
                        ForEach(Array(active.enumerated()), id: \.offset) { _, entry in
                            Text("  " + entry.address + (entry.managed ? L(" · 规则映射") : L(" · 手动映射")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
        }.padding().frame(width: 340)
    }
}

private struct BatchView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var addQuery = ""
    @State private var groupName = ""
    @State private var naming = false
    @State private var adding = false
    @State private var deleting = false

    var body: some View {
        let queued = model.rules.filter { model.batchQueue.contains($0.id) }
        let visible = queued.filter { $0.matches(query) }
        let results = Dictionary(uniqueKeysWithValues: model.batchResults.map { ($0.id, $0) })
        let usable = model.batchResults.filter { $0.candidate != nil && model.batchIDs.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 16) {
            WorkHeader(section: "", title: L("批量处理"),
                       subtitle: L("为多条规则选出合适的地址，再统一应用。")) {
                Button {
                    addQuery = ""
                    adding.toggle()
                } label: {
                    Label(L("添加规则"), systemImage: "plus")
                }
                .buttonStyle(WorkButtonStyle(quietAccent: true))
                .disabled(model.rules.isEmpty || model.batchRunning)
                .popover(isPresented: $adding, arrowEdge: .bottom) { ruleAdder }
            }
            WorkPanel {
                HStack(spacing: 10) {
                    SearchField(placeholder: L("筛选待处理任务"), text: $query).frame(maxWidth: 300)
                    Text(L("已选 \(model.batchRules.count) 条 · \(usable) 条可应用"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button {
                        model.batchIDs.formUnion(queued.map(\.id))
                    } label: { Label(L("全选"), systemImage: "checkmark") }
                    .disabled(queued.isEmpty)
                    Button {
                        model.batchIDs.formSymmetricDifference(queued.map(\.id))
                    } label: { Label(L("反选"), systemImage: "arrow.clockwise") }
                    .disabled(queued.isEmpty)
                    Button {
                        model.removeFromBatch(model.batchIDs)
                    } label: { Label(L("移除勾选"), systemImage: "minus.circle") }
                    .disabled(model.batchRules.isEmpty)
                    Button { model.removeFromBatch(model.batchQueue) } label: {
                        Label(L("清空列表"), systemImage: "trash")
                    }
                        .disabled(model.batchQueue.isEmpty)
                }
                .buttonStyle(WorkButtonStyle())
                .disabled(model.batchRunning)
                .padding(.horizontal, 14)
                .frame(height: 47)
                Divider()
                Table(visible) {
                    TableColumn(" ") { rule in
                        Toggle(isOn: Binding(
                            get: { model.batchIDs.contains(rule.id) },
                            set: { value in
                                if value { model.batchIDs.insert(rule.id) }
                                else { model.batchIDs.remove(rule.id) }
                            }
                        )) { Text(model.ruleName(rule)) }
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(model.batchRunning)
                    }.width(29)
                    TableColumn(L("规则")) { rule in Text(model.ruleName(rule)).lineLimit(1) }
                        .width(min: 128, ideal: 190)
                    TableColumn(L("域名")) { rule in
                        Text(rule.domains.first ?? "—").lineLimit(1).foregroundStyle(.secondary)
                    }.width(min: 100, ideal: 220)
                    TableColumn(L("推荐地址")) { rule in
                        Text(results[rule.id]?.candidate?.address ?? "—").monospaced().lineLimit(1)
                    }.width(min: 120, ideal: 160)
                    TableColumn(L("延迟")) { rule in
                        Text(results[rule.id]?.candidate?.latency.map { String(format: "%.1f ms", $0) } ?? "—")
                            .monospacedDigit()
                    }.width(min: 65, ideal: 84)
                    TableColumn(L("状态")) { rule in
                        let result = results[rule.id]
                        let pending = model.batchPhases[rule.id].map(localizedText)
                            ?? (model.batchIDs.contains(rule.id) ? L("待优化") : L("未选择"))
                        let text = result?.candidate != nil ? L("可应用") : result != nil ? L("无可用地址") : pending
                        Text(text).foregroundStyle(result?.candidate != nil ? Theme.accent : .secondary)
                    }.width(min: 70, ideal: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: Rule.ID.self) { ids in
                    if !ids.isEmpty {
                        Button(L("移除任务")) { model.removeFromBatch(ids) }.disabled(model.batchRunning)
                        Divider()
                    }
                    RuleCategoryMenu(model: model, action: model.addToBatch)
                }
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView(
                            queued.isEmpty ? L("暂无待处理任务") : L("没有匹配的规则"),
                            systemImage: "checklist",
                            description: Text(queued.isEmpty ? L("点击「添加规则」，或右键按分类添加。") : "")
                        )
                        .allowsHitTesting(false)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    WorkStatus(text: model.writing ? L("正在保存 Hosts…")
                               : model.batchRunning ? L("已完成 \(model.batchResults.count)/\(model.batchRules.count) 条")
                               : L("应用前可预览 Hosts 变更"),
                               inProgress: model.writing || model.batchRunning)
                        .font(.callout)
                        .foregroundStyle(model.writing || model.batchRunning ? Theme.accent : .secondary)
                    Spacer()
                    Button { Task { await model.applyBatch() } } label: {
                        Label(L("应用结果…"), systemImage: "checkmark")
                    }
                        .buttonStyle(WorkButtonStyle(prominent: true))
                        .disabled(model.phase != nil || usable == 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
            }
            batchControls
        }
        .alert(L("新建分组"), isPresented: $naming) {
            TextField(L("分组名称"), text: $groupName)
            Button(L("取消"), role: .cancel) {}
            Button(L("新建")) { model.createGroup(groupName) }
        }
        .confirmationDialog(L("删除当前分组？"), isPresented: $deleting) {
            Button(L("删除"), role: .destructive) {
                if let id = model.activeGroupID { model.deleteGroup(id) }
            }
        }
    }

    private var ruleAdder: some View {
        VStack(alignment: .leading, spacing: 9) {
            SearchField(placeholder: L("查找规则或域名"), text: $addQuery)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rules.filter { $0.matches(addQuery) }) { rule in
                        let queued = model.batchQueue.contains(rule.id)
                        Button { model.addToBatch(rule) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.ruleName(rule)).lineLimit(1)
                                    Text(rule.domains.first ?? model.groupName(rule.group))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: queued ? "checkmark" : "plus")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 6)
                            .frame(minHeight: 33)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.ruleName(rule))
                        .accessibilityValue(queued ? L("已添加") : L("添加"))
                        .disabled(queued || model.batchRunning)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 350, height: 360)
    }

    private var batchControls: some View {
        HStack(spacing: 8) {
            Picker(L("分组"), selection: Binding(get: { model.activeGroupID }, set: model.loadGroup)) {
                Text(L("默认分组")).tag(UUID?.none)
                ForEach(model.groups) { group in Text(group.name).tag(Optional(group.id)) }
            }
            .labelsHidden()
            .frame(width: 145)
            .disabled(model.batchRunning)
            Button(action: model.saveActiveGroup) { Label(L("保存"), systemImage: "tray.and.arrow.down") }
                .disabled(model.batchRunning)
            Button { groupName = ""; naming = true } label: { Label(L("新建"), systemImage: "plus") }
                .disabled(model.batchRunning)
            Button { deleting = true } label: { Label(L("删除"), systemImage: "trash") }
                .disabled(model.batchRunning || model.activeGroupID == nil)
            Spacer()
            Button(action: model.runBatch) { Label(L("开始批量优化"), systemImage: "play") }
                .buttonStyle(WorkButtonStyle(prominent: true))
                .disabled(model.batchRules.isEmpty || model.phase != nil || model.writing)
            Button(action: model.cancel) { Label(L("停止"), systemImage: "stop") }
                .disabled(!model.batchRunning || model.writing)
        }
        .buttonStyle(WorkButtonStyle())
        .modifier(GlassControls())
    }
}

private struct HostsView: View {
    private struct ReloadRequest: Equatable {
        let manualCount: Int
        let settingsID: UUID?
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var discarding = false
    @State private var showsFind = false
    @State private var showsReplace = false
    @State private var findRequest = 0
    @State private var finding = false
    @State private var findQuery = ""
    @State private var replacement = ""
    @State private var matches: [NSRange] = []
    @State private var matchIndex = 0
    @State private var edit: HostsEditorEdit?
    @State private var manualReloadCount = 0
    @State private var handledManualReloadCount = 0
    @State private var completedReload: ReloadRequest?
    @State private var saving = false

    private var match: NSRange? { showsFind && matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }

    private var reloadRequest: ReloadRequest {
        ReloadRequest(manualCount: manualReloadCount, settingsID: model.settingsHostsRefreshID)
    }

    private var refreshing: Bool { completedReload != reloadRequest }

    private var status: String {
        if model.writing || saving { return L("正在保存 Hosts…") }
        if finding { return L("正在打开查找栏…") }
        if refreshing { return L("正在刷新 Hosts…") }
        return localizedText(model.hostsStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkHeader(section: "", title: L("Hosts 编辑"), subtitle: "~/etc/hosts",
                       status: status, statusInProgress: refreshing || finding || saving || model.writing) {
                HStack(spacing: 7) {
                    Button {
                        finding = true
                        findRequest += 1
                        updateMatches()
                        withAnimation(reduceMotion ? nil : WorkMotion.disclosure) { showsFind = true }
                    } label: {
                        Label(L("查找"), systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f")
                    Button {
                        if model.draft == model.hosts { manualReloadCount += 1 } else { discarding = true }
                    } label: {
                        Label(L("重新加载"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.writing || refreshing)
                    Button {
                        let url = HostsDocument.systemURL
                        if !NSWorkspace.shared.open(url) { model.warning = L("无法用外部编辑器打开 Hosts。") }
                    } label: {
                        Label(L("外部编辑器"), systemImage: "square.and.pencil")
                    }
                    Button(action: save) {
                        Label(L("保存"), systemImage: "checkmark")
                    }
                        .buttonStyle(WorkButtonStyle(prominent: true))
                        .keyboardShortcut("s")
                        .disabled(model.draft == model.hosts || saving || model.writing || model.phase != nil)
                }
                .buttonStyle(WorkButtonStyle())
            }
            WorkPanel {
                HStack {
                    Label("hosts", systemImage: "doc.text").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 39)
                .background(Theme.sidebar)
                Divider()
                if showsFind {
                    findBar
                    Divider()
                }
                NativeTextEditor(text: $model.draft, session: model.editorSession, findMatch: match, edit: edit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text(L("\(model.draft.components(separatedBy: .newlines).count) 行"))
                    Spacer()
                    Text(model.draft.contains("\r\n") ? "UTF-8 · CRLF" : "UTF-8 · LF")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 29)
                .background(Theme.sidebar)
            }
        }
        .task(id: reloadRequest) { [request = reloadRequest] in
            guard !Task.isCancelled else { return }
            let automatically = request.manualCount == handledManualReloadCount
            handledManualReloadCount = request.manualCount
            model.reloadHosts(automatically: automatically)
            // Keep feedback visible even when the file is read before the next frame.
            try? await Task.sleep(for: WorkMotion.feedback)
            guard !Task.isCancelled else { return }
            completedReload = request
        }
        .task(id: findRequest) {
            guard finding else { return }
            try? await Task.sleep(for: WorkMotion.feedback)
            if !Task.isCancelled { finding = false }
        }
        .onChange(of: model.draft) { _, value in
            if value != model.hosts { model.hostsStatus = "有未保存的更改" }
            if showsFind { updateMatches() }
        }
        .onChange(of: findQuery) { _, _ in
            matchIndex = 0
            updateMatches()
        }
        .confirmationDialog(L("舍弃未保存的编辑？"), isPresented: $discarding) {
            Button(L("舍弃并重新加载"), role: .destructive) { manualReloadCount += 1 }
        }
    }

    private var findBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SearchField(placeholder: L("查找文件内容"), text: $findQuery, controlHeight: 34, focusRequest: findRequest)
                    .frame(maxWidth: 330)
                    .onSubmit { moveMatch(by: 1) }
                if !findQuery.isEmpty {
                    Text(matches.isEmpty ? L("无匹配") : L("第 \(matchIndex + 1) 项，共 \(matches.count) 项"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                findButton(L("上一处匹配"), symbol: "chevron.up") { moveMatch(by: -1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(matches.isEmpty)
                findButton(L("下一处匹配"), symbol: "chevron.down") { moveMatch(by: 1) }
                    .keyboardShortcut("g")
                    .disabled(matches.isEmpty)
                Button {
                    withAnimation(reduceMotion ? nil : WorkMotion.disclosure) { showsReplace.toggle() }
                } label: {
                    Label(L("替换"), systemImage: showsReplace ? "chevron.up" : "chevron.down")
                }
                .accessibilityValue(showsReplace ? L("已展开") : L("已收起"))
                findButton(L("关闭查找"), symbol: "xmark", action: closeFind)
            }
            if showsReplace {
                HStack(spacing: 8) {
                    SearchField(placeholder: L("替换为"), text: $replacement, controlHeight: 34,
                                symbol: "arrow.left.arrow.right")
                        .frame(maxWidth: 330)
                        .onSubmit { replace(all: false) }
                    Button(L("替换")) { replace(all: false) }
                        .disabled(match == nil || model.writing)
                    Button(L("全部替换")) { replace(all: true) }
                        .disabled(matches.isEmpty || model.writing)
                }
            }
        }
        .buttonStyle(WorkButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .onExitCommand(perform: closeFind)
        .transition(.opacity)
    }

    private func findButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 14, height: 14) }
            .accessibilityLabel(title)
            .help(title)
    }

    private func closeFind() {
        withAnimation(reduceMotion ? nil : WorkMotion.disclosure) { showsFind = false }
    }

    private func updateMatches() {
        matches = HostsDocument.findRanges(of: findQuery, in: model.draft)
        matchIndex = min(matchIndex, max(0, matches.count - 1))
    }

    private func moveMatch(by offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
    }

    private func replace(all: Bool) {
        guard !model.writing, let match else { return }
        let text = model.draft
        let document = text as NSString
        if all {
            let range = NSRange(location: 0, length: document.length)
            let proposed = document.replacingOccurrences(of: findQuery, with: replacement, options: .caseInsensitive, range: range)
            guard proposed != text else { return }
            edit = HostsEditorEdit(expected: text, range: range, replacement: proposed)
        } else {
            guard document.substring(with: match) != replacement else { moveMatch(by: 1); return }
            edit = HostsEditorEdit(expected: text, range: match, replacement: replacement)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let deadline = ContinuousClock.now.advanced(by: WorkMotion.feedback)
        Task {
            await model.saveDraft()
            try? await Task.sleep(until: deadline, clock: .continuous)
            saving = false
        }
    }

}

@MainActor
func previewBinding(_ model: AppModel, fromSettings: Bool) -> Binding<WritePreview?> {
    Binding(
        get: { model.preview?.fromSettings == fromSettings ? model.preview : nil },
        set: { model.preview = $0 }
    )
}

struct WriteReview: View {
    @ObservedObject var model: AppModel
    let change: WritePreview

    private var diff: [(String, Bool)] {
        let before = change.expected.components(separatedBy: .newlines)
        let after = change.proposed.components(separatedBy: .newlines)
        // Count line occurrences in linear time even for a pasted or heavily reordered file.
        let oldCounts = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        let newCounts = Dictionary(after.map { ($0, 1) }, uniquingKeysWith: +)
        func unmatched(_ lines: [String], against counts: [String: Int]) -> [String] {
            var remaining = counts
            return lines.filter { line in
                let count = remaining[line, default: 0]
                if count == 0 { return true }
                remaining[line] = count - 1
                return false
            }
        }
        return unmatched(before, against: newCounts).map { ($0, false) } +
            unmatched(after, against: oldCounts).map { ($0, true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(localizedText(change.title)).font(.headline)
            Text(model.preferences.backupEnabled ? L("确认要写入系统 Hosts 的更改。保存时会备份原文件。") : L("确认要写入系统 Hosts 的更改。"))
                .foregroundStyle(.secondary)
            let lines = diff
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty { Text(L("文件行的顺序或换行格式有变更。")).foregroundStyle(.secondary) }
                    ForEach(Array(lines.prefix(500).enumerated()), id: \.offset) { _, item in
                        Text((item.1 ? "+ " : "− ") + item.0)
                            .foregroundStyle(item.1 ? Color.green : Color.red)
                    }
                    if lines.count > 500 { Text(L("还有 \(lines.count - 500) 行变更。")) }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if let warning = model.warning {
                Label(localizedText(warning), systemImage: "exclamationmark.circle").foregroundStyle(.red)
            } else if !model.writerEnabled {
                Label(L("首次写入需要启用后台助手。"), systemImage: "lock").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("取消")) { model.warning = nil; model.preview = nil }
                    .keyboardShortcut(.cancelAction).disabled(model.writing)
                if model.writerEnabled {
                    Button(L("确认写入")) { Task { await model.confirm(change) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.writing)
                } else {
                    Button(L("启用 Hosts 写入"), action: model.enableWriter).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(model.writing)
    }
}

