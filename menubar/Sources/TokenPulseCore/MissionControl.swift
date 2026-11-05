import AppKit
import Charts
import SwiftUI

/// Immutable presentation tree over the existing menu actions. Refreshes replace the tree,
/// while route keys stay stable so a timer cannot bounce the user out of a submenu.
struct MissionRow: Identifiable {
    let id: String
    let title: String
    let item: NSMenuItem
    let children: [MissionRow]
    var separator: Bool { item.isSeparatorItem }
    var actionable: Bool { item.action != nil }
    var enabled: Bool { item.isEnabled }
    var checked: Bool { item.state == .on }
    var isChoiceMenu: Bool { title != "Notifications" && !children.isEmpty && children.allSatisfy { $0.separator || ($0.actionable && $0.children.isEmpty) } }

    static func read(_ menu: NSMenu, prefix: String = "root") -> [MissionRow] {
        menu.items.enumerated().map { index, item in
            let stable = item.submenu == nil ? "row-\(index)" : String(item.title.split(separator: " ").first ?? "submenu")
            let id = "\(prefix)/\(stable)"
            let text = (item.view?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? item.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MissionRow(id: id, title: text, item: item,
                              children: item.submenu.map { read($0, prefix: id) } ?? [])
        }
    }
}

struct MissionMeter: Identifiable {
    let id: String
    let label: String
    let percent: Int
    let reset: String?
    var resetAt: Date? = nil
}

struct MissionProvider: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let resource: String?
    let enabled: Bool
    let stale: Bool
    let row: MissionRow?
    var meters: [MissionMeter] = []
    var headline: String?
    var spendTint: NSColor?
    var amounts: [String: Double] = [:]
    var resetNote: String? = nil
    var summary: String {
        if let headline { return headline }
        guard let title = row?.title else { return enabled ? "No current data" : "Disabled" }
        return title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }
}

struct MissionAdvisory: Identifiable {
    let id = UUID()
    var provider = "Claude"
    var scope = "Local Claude Code sessions · this month"
    let title: String
    let body: String
    let date = Date()
}

final class MissionModel: ObservableObject {
    @Published var rows: [MissionRow] = []
    @Published var providers: [MissionProvider] = []
    @Published var route = "overview"
    @Published var path: [String] = []
    @Published var updated: Date?
    @Published var refreshing = false
    @Published var contentHeight: CGFloat = 480
    @Published var maximumHeight: CGFloat = 700
    @Published var advisories: [MissionAdvisory] = []
    @Published var efficiencyEnabled = false
    @Published var efficiencyMessage = "Loading local Claude Code sessions…"
    @Published var score: ScoreboardModel?
    @Published var workCredits: ChatGPTWorkUsageSnapshot?
    @Published var combinedAmounts: [Double] = []
    @Published var combinedLines: [String] = []
    @Published var showsCombinedSpend = false
    @Published var spendChart: [SpendChartPoint] = []
    @Published var balance: Double?
    @Published var balanceNeedsAttention = false
    var refresh: () -> Void = {}
    var invoke: (NSMenuItem) -> Void = { _ in }
    var resize: (NSSize) -> Void = { _ in }

    var options: MissionRow? { rows.first { $0.title == "Options" } }
    func show(_ route: String) {
        // Combined spend chips open the spend chart; keep old "combined" deep links there too.
        self.route = route == "combined" ? "spend" : route
        path = []
    }
    var baseRows: [MissionRow] {
        if route == "options" { return options?.children ?? [] }
        return providers.first { $0.id == route }?.row?.children ?? []
    }
    var currentRows: [MissionRow] {
        path.reduce(baseRows) { rows, key in rows.first { $0.id == key }?.children ?? [] }
    }
    var currentTitle: String {
        var title = route == "options" ? "Display & options" : providers.first { $0.id == route }?.name ?? "TokenPulse"
        var cursor = baseRows
        for key in path {
            guard let next = cursor.first(where: { $0.id == key }) else { break }
            title = next.title; cursor = next.children
        }
        if title == "Colors", let sourceID = path.first, let source = options?.children.first(where: { $0.id == sourceID }) {
            let name = source.title.components(separatedBy: " · ").first ?? source.title
            return name + " · Colors"
        }
        if title == "By product" { return "Credits by product" }
        return title
    }
    func back() { if path.isEmpty { show("overview") } else { path.removeLast() } }
    func perform(_ row: MissionRow) { if row.enabled { invoke(row.item) } }
}

private enum MissionStyle {
    static let background = Color(red: 0.055, green: 0.098, blue: 0.161)
    static let panel = Color(red: 0.098, green: 0.173, blue: 0.251)
    static let line = Color(red: 0.169, green: 0.263, blue: 0.357)
    static let ink = Color(red: 0.929, green: 0.961, blue: 1)
    static let secondary = Color(red: 0.60, green: 0.68, blue: 0.78)
    static let cyan = Color(red: 0.345, green: 0.824, blue: 0.925)
    static let green = Color(red: 0.46, green: 0.88, blue: 0.70)
    static let amber = Color(red: 0.94, green: 0.80, blue: 0.52)
    static let red = Color(red: 1, green: 0.56, blue: 0.61)
}

struct MissionButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(MissionStyle.panel.opacity(configuration.isPressed ? 0.65 : 1))
            .cornerRadius(7).overlay(RoundedRectangle(cornerRadius: 7).stroke(MissionStyle.line))
    }
}

private struct MissionHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MissionControlView: View {
    @ObservedObject var model: MissionModel
    private var size: NSSize {
        NSSize(width: 780, height: min(model.maximumHeight, max(460, ceil(model.contentHeight + 138))))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = NSImage(named: "TokenPulseMark") { Image(nsImage: icon).resizable().scaledToFit().frame(width: 30, height: 30) }
                Text("TokenPulse").font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                if model.route != "overview" {
                    Button(model.route == "spend" ? "Overview" : "Back") { model.back() }
                        .buttonStyle(MissionButton())
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(MissionButton())
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.refreshing)
                .help("Refresh")
                .accessibilityLabel("Refresh")
                Button {
                    model.show("options")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(MissionButton())
                .help("Preferences")
                .accessibilityLabel("Preferences")
            }.padding(.horizontal, 18).padding(.vertical, 15)
            line
            HStack(spacing: 4) {
                tab("Overview", "overview")
                tab("Efficiency", "efficiency")
                tab("Scoreboard", "scoreboard")
                tab("Alerts", "alerts")
                Spacer(minLength: 12)
                if model.showsCombinedSpend { combinedSpendBar }
            }.padding(.horizontal, 14).padding(.vertical, 8)
            line
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(MissionStyle.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.route == "overview" { overview }
                        else if model.route == "spend" { spendBreakdown }
                        else if model.route == "efficiency" || model.route == "scoreboard" { efficiency }
                        else if model.route == "alerts" { alerts }
                        else { detail }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geo in Color.clear.preference(key: MissionHeight.self, value: geo.size.height) })
                }.id(model.route + model.path.joined(separator: ":"))
            }.frame(maxHeight: .infinity)
            line
            HStack {
                Text(model.updated.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? "Connecting to your sources…")
                Spacer()
                Button("Quit ⌘Q") { if let item = model.rows.first(where: { $0.title == "Quit TokenPulse" }) { model.perform(item) } }
                    .buttonStyle(.plain).keyboardShortcut("q", modifiers: .command)
            }.font(.system(size: 11)).foregroundColor(MissionStyle.secondary).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .foregroundColor(MissionStyle.ink).background(MissionStyle.background)
        .frame(width: size.width, height: size.height).preferredColorScheme(.dark)
        .onPreferenceChange(MissionHeight.self) { if $0 > 0 { model.contentHeight = $0 } }
        .onChange(of: size) { model.resize($0) }.onAppear { model.resize(size) }
    }
    private var line: some View { Rectangle().fill(MissionStyle.line).frame(height: 1) }
    private func tab(_ text: String, _ route: String) -> some View {
        Button { model.show(route) } label: {
            Text(text).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(model.route == route ? MissionStyle.panel : .clear).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.providers) { p in
                Button { model.show(p.id) } label: {
                    HStack(spacing: 8) { brand(p, size: 16); Text(p.name).font(.system(size: 12)); Spacer() }
                        .foregroundColor(model.route == p.id ? MissionStyle.ink : MissionStyle.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(model.route == p.id ? MissionStyle.background : .clear).cornerRadius(7)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 18).frame(width: 150)
            .background(MissionStyle.panel)
    }
    /// Compact work-spend chips on the tab bar. Panel fill alone would disappear into the
    /// bar, so these use a cyan-tinted surface and stroke.
    private var combinedSpendBar: some View {
        Group {
            if model.combinedLines.isEmpty {
                Text("Waiting for work spend")
                    .font(.system(size: 10))
                    .foregroundColor(MissionStyle.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(spendChipFill)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(MissionStyle.cyan.opacity(0.28)))
                    .cornerRadius(7)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(model.combinedLines.prefix(4).enumerated()), id: \.offset) { index, text in
                        let parts = text.components(separatedBy: ": ")
                        let rawLabel = parts.first ?? text
                        let label = rawLabel.hasPrefix("Projected") ? "Proj. eom"
                            : rawLabel.hasPrefix("Workday") ? "Workday avg"
                            : rawLabel
                        let amount = model.combinedAmounts.indices.contains(index) ? model.combinedAmounts[index] : nil
                        let value = amount.map(Fmt.exactMoney) ?? parts.dropFirst().joined(separator: ": ")
                        // Tint: Today + Workday avg use day-scale caps; Month + Proj. eom use month.
                        let tintIndex = (index == 0 || index == 2) ? 0 : 1
                        Button { model.show("spend") } label: {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(MissionStyle.secondary)
                                Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .foregroundColor(amount.map { combinedSpendColor($0, index: tintIndex) } ?? MissionStyle.ink)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(spendChipFill)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                                model.route == "spend" ? MissionStyle.cyan.opacity(0.55) : MissionStyle.cyan.opacity(0.28)))
                            .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                        .help("Daily spend chart")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your spend")
        .accessibilityHint("Opens the daily spend chart")
    }
    private var spendChipFill: Color {
        Color(red: 0.06, green: 0.16, blue: 0.24)
    }
    private var spendBreakdown: some View {
        let points = model.spendChart
        let today = model.combinedAmounts.indices.contains(0) ? model.combinedAmounts[0] : 0
        let month = model.combinedAmounts.indices.contains(1) ? model.combinedAmounts[1] : 0
        let workdayAvg = model.combinedAmounts.indices.contains(2) ? model.combinedAmounts[2] : 0
        let projected = model.combinedAmounts.indices.contains(3) ? model.combinedAmounts[3] : 0
        let recorded = points.filter { $0.actualUSD != nil }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text("Month-to-date spend").font(.system(size: 18, weight: .semibold))
            Text("Solid line climbs with recorded month-to-date totals. The dotted line continues to projected month-end.")
                .font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
            HStack(spacing: 10) {
                metricCard("Today", Fmt.exactMoney(today), color: combinedSpendColor(today, index: 0))
                metricCard("Month", Fmt.exactMoney(month), color: combinedSpendColor(month, index: 1))
                metricCard("Workday avg", Fmt.exactMoney(workdayAvg), color: combinedSpendColor(workdayAvg, index: 0))
                metricCard("Proj. eom", Fmt.exactMoney(projected), color: combinedSpendColor(projected, index: 1))
            }
            if points.isEmpty {
                note("No spend to chart yet. Enable a work source and refresh.")
            } else {
                Chart {
                    ForEach(points.filter { $0.actualUSD != nil }) { point in
                        if let actual = point.actualUSD {
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Spend", actual),
                                series: .value("Series", "Actual")
                            )
                            .foregroundStyle(MissionStyle.green)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.catmullRom)
                            PointMark(
                                x: .value("Day", point.day),
                                y: .value("Spend", actual)
                            )
                            .foregroundStyle(point.isToday ? MissionStyle.cyan : MissionStyle.green)
                            .symbolSize(point.isToday ? 64 : 36)
                        }
                    }
                    ForEach(points.filter { $0.projectedUSD != nil }) { point in
                        if let projectedDay = point.projectedUSD {
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Projected", projectedDay),
                                series: .value("Series", "Projected")
                            )
                            .foregroundStyle(MissionStyle.amber)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .interpolationMethod(.linear)
                        }
                    }
                    if let eom = points.last, let projectedEom = eom.projectedUSD {
                        PointMark(
                            x: .value("Day", eom.day),
                            y: .value("Projected", projectedEom)
                        )
                        .foregroundStyle(MissionStyle.amber)
                        .symbolSize(64)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(MissionStyle.line)
                        AxisValueLabel {
                            if let day = value.as(Int.self) {
                                Text("\(day)").font(.system(size: 9)).foregroundColor(MissionStyle.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(MissionStyle.line)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(Fmt.money(amount)).font(.system(size: 9)).foregroundColor(MissionStyle.secondary)
                            }
                        }
                    }
                }
                .frame(height: 220)
                .padding(14)
                .background(MissionStyle.panel)
                .cornerRadius(10)
                HStack(spacing: 14) {
                    legendSwatch(MissionStyle.green, "Month-to-date")
                    legendSwatch(MissionStyle.cyan, "Today")
                    legendSwatch(MissionStyle.amber, "Projected to eom")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundColor(MissionStyle.secondary)
                if recorded <= 1 {
                    note("TokenPulse stores each day’s month-to-date locally as you refresh. Earlier days in this month fill in going forward.")
                }
            }
        }
    }
    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 4)
            Text(label)
        }
    }
    /// Today uses the day-scale of the summed work caps; month and projected use the month caps.
    private func combinedSpendColor(_ usd: Double, index: Int) -> Color {
        guard Prefs.spendColorsEnabled else { return MissionStyle.ink }
        let policy = Config().spendRedUSD
        var cap = 0.0
        var orange = 75.0
        var yellow = 50.0
        var good: GoodZoneStyle = .green
        var found = false
        func take(_ colors: SpendUpColorConfig, policyUSD: Double) {
            if !found {
                orange = colors.orangePercent
                yellow = colors.yellowPercent
                good = colors.goodStyle
                found = true
            }
            cap += colors.effectiveCap(policyUSD: policyUSD)
        }
        if Prefs.enabledCursor && !Prefs.cursorIsPersonal {
            take(Prefs.cursorWorkColors(policyUSD: policy), policyUSD: policy)
        }
        if Prefs.enabledClaude && !Prefs.claudeIsPersonal {
            take(Prefs.claudeColors(policyUSD: policy), policyUSD: policy)
        }
        if Prefs.enabledChatGPT && !Prefs.chatGPTIsPersonal {
            take(Prefs.chatGPTWorkColors(), policyUSD: ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD)
        }
        guard found, cap > 0 else { return MissionStyle.ink }
        let effective = index == 0 ? SpendTint.dailyCap(cap) : cap
        let tint = SpendTint.levelSpendUp(usd, cap: effective, orangePercent: orange, yellowPercent: yellow)
        guard let ns = tint.menuColor(goodStyle: good) else { return MissionStyle.ink }
        return Color(nsColor: ns)
    }
    @ViewBuilder private func brand(_ p: MissionProvider, size: CGFloat) -> some View {
        let resource = p.resource
        let original = resource.flatMap { NSImage(named: $0) ?? Bundle.main.url(forResource: $0, withExtension: "png").flatMap { NSImage(contentsOf: $0) } } ?? NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.name)
        if let image = ProviderArtwork.image(p.name, original: original, plainColor: NSColor(srgbRed: 0.60, green: 0.68, blue: 0.78, alpha: 1)) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else { Image(systemName: p.symbol).font(.system(size: size)).foregroundColor(MissionStyle.cyan).frame(width: size, height: size) }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.balanceNeedsAttention, let balance = model.balance {
                HStack(spacing: 0) {
                    Rectangle().fill(MissionStyle.amber).frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep an eye on API balance").font(.system(size: 12, weight: .semibold))
                        Text("\(Fmt.exactMoney(balance)) estimated · reset your baseline after topping up")
                            .font(.system(size: 11)).foregroundColor(MissionStyle.secondary)
                    }.padding(14)
                    Spacer(minLength: 0)
                }.fixedSize(horizontal: false, vertical: true).background(MissionStyle.panel)
            }
            if model.providers.isEmpty { note("Connecting to your sources…") }
            else { providerOverviewGrid }
            note("Allowances, estimated balances, and spend remain separate.")
        }
    }
    /// Enabled cards come first in side-by-side pairs. A lone enabled card shares its row
    /// with at most 3 disabled cards — that cap keeps the left card from stretching with a
    /// long stack. Extra disabled cards start on the next line in pairs.
    private var providerOverviewGrid: some View {
        let enabled = model.providers.filter(\.enabled)
        let disabled = model.providers.filter { !$0.enabled }
        let pairedEnabled = Array(enabled.prefix(enabled.count - (enabled.count % 2)))
        let loneEnabled = enabled.count % 2 == 1 ? enabled.last : nil
        let besideCap = 3
        let besideDisabled = loneEnabled == nil ? [] : Array(disabled.prefix(besideCap))
        let overflowDisabled = loneEnabled == nil ? disabled : Array(disabled.dropFirst(besideCap))
        return VStack(spacing: 10) {
            providerPairRows(pairedEnabled)
            if let lone = loneEnabled {
                HStack(alignment: .top, spacing: 10) {
                    providerCard(lone, expandVertically: true)
                    if besideDisabled.isEmpty {
                        Color.clear.frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(besideDisabled) { providerCard($0, expandVertically: false) }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            providerPairRows(overflowDisabled)
        }
    }
    private func providerPairRows(_ providers: [MissionProvider]) -> some View {
        let pairs = stride(from: 0, to: providers.count, by: 2).map { Array(providers[$0..<min($0 + 2, providers.count)]) }
        return VStack(spacing: 10) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(pair) { providerCard($0, expandVertically: true) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func openProviderOptions(_ p: MissionProvider) {
        model.show("options")
        if let option = model.options?.children.first(where: { $0.title.hasPrefix(p.name) }) {
            model.path = [option.id]
        }
    }
    private func statusDot(_ enabled: Bool) -> some View {
        Circle().fill(enabled ? MissionStyle.green : MissionStyle.red).frame(width: 8, height: 8)
            .accessibilityLabel(enabled ? "Enabled" : "Disabled")
    }
    private func providerCard(_ p: MissionProvider, expandVertically: Bool = true) -> some View {
        Button {
            if p.enabled { model.show(p.id) } else { openProviderOptions(p) }
        } label: {
            Group {
                if p.enabled { enabledProviderCard(p) } else { disabledProviderCard(p) }
            }
            .frame(maxWidth: .infinity, maxHeight: expandVertically ? .infinity : nil, alignment: .topLeading)
            .background(MissionStyle.panel).cornerRadius(9)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(MissionStyle.line))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: expandVertically ? .infinity : nil, alignment: .top)
        .accessibilityHint(p.enabled ? "Shows provider details" : "Opens provider options to enable")
    }
    private func disabledProviderCard(_ p: MissionProvider) -> some View {
        HStack(alignment: .center, spacing: 10) {
            brand(p, size: 18)
            Text(p.name).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text("Disabled").font(.system(size: 12, weight: .semibold)).foregroundColor(MissionStyle.secondary)
            statusDot(false)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
    private func enabledProviderCard(_ p: MissionProvider) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                brand(p, size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(.system(size: 13, weight: .semibold))
                    Text(providerSubtitle(p)).font(.system(size: 11)).foregroundColor(MissionStyle.secondary)
                }
                Spacer(minLength: 0)
                statusDot(true).padding(.top, 4)
            }
            if !p.meters.isEmpty {
                VStack(spacing: 7) {
                    ForEach(p.meters) { meter in
                        VStack(alignment: .leading, spacing: 4) {
                          HStack(spacing: 7) {
                            Text(meter.label == "5-hour window" ? "5H" : meter.label == "Weekly window" ? "Weekly" : "Left")
                                .font(.system(size: 10, weight: .medium)).foregroundColor(MissionStyle.secondary).frame(width: 36, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(MissionStyle.line)
                                    Capsule().fill(MissionStyle.cyan).frame(width: geo.size.width * CGFloat(min(100, max(0, meter.percent))) / 100)
                                }
                            }.frame(height: 5)
                            Text("\(meter.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundColor(summaryColor(p, percent: Double(meter.percent))).frame(width: 39, alignment: .trailing)
                          }
                          Text(meter.reset.map { "Resets " + $0 } ?? "Reset time unavailable")
                            .font(.system(size: 10)).foregroundColor(MissionStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        }.accessibilityElement(children: .ignore).accessibilityLabel("\(meter.label): \(meter.percent)% remaining. Resets \(meter.reset ?? "not reported")")
                    }
                }.padding(.leading, 30)
            } else {
                Text(p.summary).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundColor(p.spendTint.map { Color(nsColor: $0) } ?? summaryColor(p))
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 30)
                if let reset = p.resetNote { Text(reset).font(.system(size: 10)).foregroundColor(MissionStyle.secondary).padding(.leading, 30).fixedSize(horizontal: false, vertical: true) }
            }
            Text(p.stale ? "Last received data · refresh delayed" : p.id == "openai" ? "Estimated balance / reported spend  ›" : "View details  ›")
                .font(.system(size: 10)).foregroundColor(p.stale ? MissionStyle.amber : MissionStyle.secondary).padding(.leading, 30)
        }.padding(13).frame(maxWidth: .infinity, minHeight: 113, alignment: .topLeading)
    }
    private func providerSubtitle(_ p: MissionProvider) -> String {
        switch p.id {
        case "chatgpt": return Prefs.chatGPTIsPersonal ? "5-hour / weekly allowances" : "Work credits · planning estimate"
        case "cursor": return Prefs.cursorIsPersonal ? "Included Pro allowance" : "Work spend · today / month"
        case "claude": return Prefs.claudeIsPersonal ? "5-hour / weekly allowances" : "Work spend · today / month"
        case "grok": return "Weekly allowance"
        default: return "Estimated prepaid balance"
        }
    }
    private func weeklyPercent(_ p: MissionProvider) -> Double? {
        guard p.id != "openai", let title = p.row?.title, title.contains("%") else { return nil }
        let pieces = title.components(separatedBy: "%")
        return pieces.dropLast().last.flatMap { Double($0.components(separatedBy: CharacterSet.decimalDigits.inverted).last(where: { !$0.isEmpty }) ?? "") }
    }
    private func summaryColor(_ p: MissionProvider, percent: Double? = nil) -> Color {
        guard Prefs.spendColorsEnabled else { return MissionStyle.ink }
        let tint: SpendTint
        let good: GoodZoneStyle
        if let pct = percent ?? weeklyPercent(p) {
            let config: RemainingColorConfig
            switch p.id {
            case "chatgpt": config = Prefs.chatGPTColors()
            case "cursor": config = Prefs.cursorPersonalColors()
            case "claude": config = Prefs.claudePersonalColors()
            default: config = Prefs.grokBotColors()
            }
            tint = config.level(for: pct); good = config.goodStyle
        } else if p.id == "openai", let balance = model.balance {
            let config = Prefs.openAIColors(); tint = config.level(for: balance); good = config.goodStyle
        } else { return MissionStyle.ink }
        guard let color = tint.menuColor(goodStyle: good) else { return MissionStyle.ink }
        return Color(nsColor: color)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(model.currentTitle).font(.system(size: 18, weight: .semibold))
                if model.path.isEmpty, let account = accountLabel {
                    Text(account).font(.system(size: 11)).foregroundColor(MissionStyle.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(MissionStyle.panel).cornerRadius(5)
                }
                if let provider = model.providers.first(where: { $0.id == model.route }), model.path.isEmpty {
                    Spacer(minLength: 8)
                    Button { openProviderOptions(provider) } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(MissionButton())
                    .help("Provider options")
                    .accessibilityLabel("Provider options")
                }
            }
            if model.path.isEmpty && (model.route == "chatgpt" || model.route == "claude") {
                Text(model.workCredits == nil && accountLabel == "Personal" ? "Independent usage windows" : model.route == "chatgpt" ? "API-equivalent estimate · not your bill" : "Work spend · today / month")
                    .font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
            }
            if model.route == "options", model.path.isEmpty { Text("Display, accounts, and per-source thresholds").font(.system(size: 12)).foregroundColor(MissionStyle.secondary) }
            if model.path.isEmpty, let provider = model.providers.first(where: { $0.id == model.route }), !provider.meters.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(provider.meters) { meter in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(meter.label).font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
                            Text("\(meter.percent)%").font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundColor(summaryColor(provider, percent: Double(meter.percent)))
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(MissionStyle.line)
                                    Capsule().fill(MissionStyle.cyan).frame(width: geo.size.width * CGFloat(min(100, max(0, meter.percent))) / 100)
                                }
                            }.frame(height: 5)
                            Text("Remaining allowance").font(.system(size: 11)).foregroundColor(MissionStyle.secondary)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(MissionStyle.panel).cornerRadius(10)
                    }
                }
            }
            if model.path.isEmpty, model.route != "cursor", let provider = model.providers.first(where: { $0.id == model.route }) {
                ForEach(provider.meters) { meter in
                    if let reset = meter.reset { informationLine(meter.label == "5-hour window" ? "5-hour reset" : meter.label == "Weekly window" ? "Weekly reset" : "Resets", reset) }
                }
            }
            if model.path.isEmpty, model.route == "chatgpt", let work = model.workCredits {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This month").font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
                    Text(Fmt.exactMoney(work.estimatedUSD) + " est.").font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    Text(Fmt.credits(work.monthCredits) + " credits").font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(MissionStyle.panel).cornerRadius(10)
            }
            let featured = model.path.isEmpty ? model.currentRows.filter {
                if model.route == "openai" { return $0.title.hasPrefix("Estimated prepaid balance:") }
                if model.route == "chatgpt" { return false }
                return $0.title.hasPrefix("Today:") || $0.title.hasPrefix("Month:")
            } : []
            if !featured.isEmpty {
                if model.route == "chatgpt" {
                    ForEach(featured.reversed()) { statistic($0) }
                } else {
                    HStack(alignment: .top, spacing: 12) { ForEach(featured) { statistic($0) } }
                }
            }
            if model.currentRows.isEmpty {
                note(model.providers.first { $0.id == model.route }?.enabled == false ? "This source is disabled. Enable it in provider options." : "No current data. Check this provider’s sign-in and account mode. Last successful data is retained when available.")
            } else {
                let metered = model.path.isEmpty && model.providers.first(where: { $0.id == model.route })?.meters.isEmpty == false
                let remaining = model.currentRows.filter { row in
                    !(model.path.isEmpty && model.route == "chatgpt" && model.workCredits != nil && row.title.hasPrefix("Month:")) && !featured.contains(where: { $0.id == row.id }) && (!metered || !(["Included usage:", "Weekly limit:", "Five-hour limit:", "5-hour limit:"].contains(where: { row.title.hasPrefix($0) }) || (model.route != "cursor" && row.title.hasPrefix("Resets:"))))
                }
                if model.route == "options", model.path.isEmpty { displayOptions(remaining) }
                else if model.route == "options" { rows(remaining, panel: !model.currentTitle.hasSuffix("Colors")) }
                else if !remaining.isEmpty { providerInformation(remaining) }
            }
            if model.path.isEmpty, model.route == "claude", model.efficiencyEnabled {
                Button("Efficiency") { model.show("efficiency") }.buttonStyle(MissionButton())
            }
        }
    }
    private var accountLabel: String? {
        switch model.route {
        case "chatgpt": return Prefs.chatGPTIsPersonal ? "Personal" : "Work credits"
        case "cursor": return Prefs.cursorIsPersonal ? "Personal Pro" : "Work spend"
        case "claude": return Prefs.claudeIsPersonal ? "Personal" : "Work spend"
        default: return nil
        }
    }
    private func metricCard(_ label: String, _ value: String, color: Color = MissionStyle.ink) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
            Text(value).font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(MissionStyle.panel).cornerRadius(10)
    }
    private func displayOptions(_ sourceRows: [MissionRow]) -> some View {
        let sourceOptions = sourceRows.filter { row in !row.children.isEmpty && model.providers.contains { row.title.hasPrefix($0.name) } }
        let core = sourceRows.filter { row in !row.separator && !sourceOptions.contains(where: { $0.id == row.id }) && row.title != "Reset to defaults…" }
        return VStack(alignment: .leading, spacing: 14) {
            rows(core)
            Text("Sources").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 7) {
                ForEach(sourceOptions) { option in
                    Button(model.providers.first(where: { option.title.hasPrefix($0.name) })?.name ?? option.title) { model.path.append(option.id) }.buttonStyle(MissionButton())
                }
            }
            note("Pastel requires spend colors. Efficiency uses local Claude Code sessions in personal or work mode.")
            if let reset = sourceRows.first(where: { $0.title == "Reset to defaults…" }) { Button(reset.title) { model.perform(reset) }.buttonStyle(MissionButton()) }
        }
    }

    private func statistic(_ row: MissionRow) -> some View {
        let parts = row.title.components(separatedBy: ": ")
        let provider = model.providers.first { $0.id == model.route }
        let value = provider?.amounts[parts.first ?? ""].map(Fmt.exactMoney) ?? parts.dropFirst().joined(separator: ": ")
        return metricCard(parts.first ?? row.title, value, color: model.route == "openai" ? provider.map { summaryColor($0) } ?? MissionStyle.ink : MissionStyle.ink)
    }

    private func informationLine(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(name).foregroundColor(MissionStyle.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.system(size: 12)).textSelection(.enabled).padding(.vertical, 9)
            .overlay(alignment: .bottom) { line.opacity(0.6) }
    }
    private func providerInformation(_ sourceRows: [MissionRow]) -> some View {
        let info = sourceRows.filter { !$0.separator && $0.children.isEmpty }
        let links = sourceRows.filter { !$0.children.isEmpty }
        return VStack(alignment: .leading, spacing: 14) {
            if !model.path.isEmpty, !info.isEmpty, !info.allSatisfy({ $0.title.hasPrefix("(") }) {
                informationLine(model.route == "chatgpt" ? "Product" : model.route == "openai" ? "Line item" : "Model", model.route == "chatgpt" ? "Credits" : model.route == "cursor" && Prefs.cursorIsPersonal ? "Tokens" : "Spend")
            }
            ForEach(info) { row in
                let parts = row.title.components(separatedBy: ": ")
                if row.title.hasPrefix("Token totals") || row.title.hasPrefix("Estimate") || row.title.hasPrefix("Daily cost") || row.title.hasPrefix("Uses Cursor") || row.title.hasPrefix("(") {
                    note(row.title == "(no cost line items)" ? "No cost line items yet. Figures are reported through the daily cost pipeline." : row.title == "(no usage events)" || row.title == "(no usage)" ? "No usage this period." : row.title)
                } else if model.route == "cursor", model.path.isEmpty, parts.first == "Allowance", parts.count == 2, parts[1].components(separatedBy: " · ").count >= 3 {
                    let values = parts[1].components(separatedBy: " · ")
                    informationLine("Included allowance", values[0])
                    informationLine("Used / consumed", values.dropFirst().joined(separator: " · ").replacingOccurrences(of: "used ", with: ""))
                } else if parts.count == 2 { informationLine(parts[0], parts[1]) }
                else { Text(row.title).font(.system(size: 12)).foregroundColor(MissionStyle.secondary) }
            }
            if !links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(links) { row in Button(row.title) { model.path.append(row.id) }.buttonStyle(MissionButton()) }
                }
            }
        }
    }
    private func rows(_ rows: [MissionRow], panel: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let goodChoices = rows.filter { $0.title.hasPrefix("Good:") }
            if !goodChoices.isEmpty {
                HStack {
                    Text("Good zone").font(.system(size: 12))
                    Spacer()
                    Menu {
                        ForEach(goodChoices) { choice in
                            Button { model.perform(choice) } label: {
                                if choice.checked { Label(choice.title.replacingOccurrences(of: "Good: ", with: ""), systemImage: "checkmark") }
                                else { Text(choice.title.replacingOccurrences(of: "Good: ", with: "")) }
                            }
                        }
                    } label: { Text(goodChoices.first { $0.checked }?.title.replacingOccurrences(of: "Good: ", with: "") ?? "Choose…").font(.system(size: 12)).foregroundColor(MissionStyle.cyan) }
                        .menuStyle(.borderlessButton).fixedSize()
                }.padding(.vertical, 10)
            }
            ForEach(rows.filter { !$0.title.hasPrefix("Good:") }) { row in
                if row.separator { line.padding(.vertical, 8) }
                else if !row.children.isEmpty {
                    // Preset/account/display choices stay compact rather than spawning another window.
                    if row.isChoiceMenu {
                        HStack {
                            Text(fieldLabel(row.title)).font(.system(size: 12))
                            Spacer(minLength: 8)
                            Menu {
                                ForEach(row.children.filter { !$0.separator }) { choice in
                                    Button { model.perform(choice) } label: {
                                        if choice.checked { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                                    }.disabled(!choice.enabled)
                                }
                            } label: { Text(row.children.first { $0.checked }?.title ?? "Choose…").font(.system(size: 12)).foregroundColor(MissionStyle.cyan) }
                            .menuStyle(.borderlessButton).fixedSize()
                        }.padding(.vertical, 10)
                    } else {
                        Button { model.path.append(row.id) } label: {
                            HStack { Text(row.title); Spacer(); Image(systemName: "chevron.right").foregroundColor(MissionStyle.secondary) }
                                .font(.system(size: 12)).padding(.vertical, 11).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } else if row.actionable {
                    if isToggle(row) {
                        HStack {
                            Text(row.title == "Show in Menu" ? "Show in menu bar" : row.title).font(.system(size: 12))
                            Spacer()
                            Toggle(row.title, isOn: Binding(get: { row.checked }, set: { _ in model.perform(row) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(MissionStyle.cyan)
                        }.padding(.vertical, 8).disabled(!row.enabled)
                    } else {
                        Button(row.title) { model.perform(row) }.buttonStyle(MissionButton()).padding(.vertical, 5).disabled(!row.enabled)
                    }
                } else {
                    let parts = row.title.components(separatedBy: ": ")
                    if parts.count == 2 {
                        HStack(alignment: .top, spacing: 16) {
                            Text(parts[0]).foregroundColor(MissionStyle.secondary)
                            Spacer(minLength: 4)
                            Text(parts[1]).monospacedDigit().multilineTextAlignment(.trailing)
                        }.font(.system(size: 12)).textSelection(.enabled).padding(.vertical, 9)
                    } else {
                        Text(row.title).font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.vertical, 7)
                    }
                }
            }
        }.padding(panel ? 14 : 0).frame(maxWidth: .infinity, alignment: .leading).background(panel ? MissionStyle.panel : .clear).cornerRadius(10)
    }
    private func fieldLabel(_ title: String) -> String {
        if title.contains("remaining"), let color = ["Red", "Orange", "Yellow"].first(where: { title.hasPrefix($0 + " at") }) {
            return color + " below"
        }
        if title.hasPrefix("Red at") && title.contains("month") { return "Red monthly threshold" }
        if title.hasPrefix("Red at") || title.hasPrefix("Red below") { return "Red below" }
        if title.hasPrefix("Orange at") { return "Orange at % of red" }
        if title.hasPrefix("Yellow at") { return "Yellow at % of red" }
        if title.hasPrefix("Orange below") { return "Orange below" }
        if title.hasPrefix("Yellow below") { return "Yellow below" }
        return title
    }
    private func isToggle(_ row: MissionRow) -> Bool {
        row.title.hasSuffix("% remaining") || ["Enable notifications", "Low allowance alerts", "Claude model-spend advisories", "Notification sounds", "Enable", "Show in Menu", "Show daily in menu bar", "Show monthly in menu bar", "Spend colors", "Dark menu-bar background", "Pastel menu-bar colors", "Themed provider logos", "Reopen where I left off"].contains(row.title)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(MissionStyle.secondary).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading).background(MissionStyle.panel).cornerRadius(8)
    }
    @ViewBuilder private var efficiency: some View {
        if let score = model.score, model.efficiencyEnabled {
            MissionScoreboardView(model: score, compact: model.route == "efficiency") {
                model.show("scoreboard")
            }
        } else {
            Text(model.route == "scoreboard" ? "Efficiency Scoreboard" : "Efficiency").font(.system(size: 18, weight: .semibold))
            note(model.efficiencyMessage)
            Button("Claude provider options") {
                model.show("options")
                if let option = model.options?.children.first(where: { $0.title.hasPrefix("Claude") }) { model.path = [option.id] }
            }.buttonStyle(MissionButton())
        }
    }
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Alerts").font(.system(size: 18, weight: .semibold))
            if model.advisories.isEmpty { note("No advisories this session.") }
            ForEach(model.advisories) { advisory in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        if let provider = model.providers.first(where: { $0.name == advisory.provider }) { brand(provider, size: 18) }
                        Text(advisory.provider).font(.system(size: 13, weight: .semibold))
                    }
                    Text(advisory.scope).font(.system(size: 11)).foregroundColor(MissionStyle.secondary)
                    Text(advisory.title).font(.system(size: 13, weight: .semibold)).foregroundColor(MissionStyle.amber)
                    Text(advisory.body).font(.system(size: 12)).foregroundColor(MissionStyle.secondary)
                    Text(advisory.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundColor(MissionStyle.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(MissionStyle.panel).cornerRadius(10)
            }
            note("Shown at most once per day above the configured Opus spend share. macOS controls system banner appearance.")
        }
    }
}
