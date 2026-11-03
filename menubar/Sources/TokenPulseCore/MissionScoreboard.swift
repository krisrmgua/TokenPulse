import SwiftUI

/// Uses the original score model and weights; only the presentation changes.
struct MissionScoreboardView: View {
    let model: ScoreboardModel
    var compact = false
    var openFull: () -> Void = {}
    private let panel = Color(red: 0.098, green: 0.173, blue: 0.251)
    private let cyan = Color(red: 0.345, green: 0.824, blue: 0.925)
    private let secondary = Color(red: 0.60, green: 0.68, blue: 0.78)
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(compact ? "Efficiency" : "Efficiency Scoreboard").font(.system(size: 18, weight: .semibold))
            Text("Claude Code · local session analysis").font(.system(size: 12)).foregroundColor(secondary)
            Text("Model-cost comparisons are estimates, not subscription charges.").font(.system(size: 11)).foregroundColor(secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Efficiency grade \(model.grade)").font(.system(size: 12)).foregroundColor(secondary)
                    Text("\(model.score) / 100").font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundColor(cyan)
                    Text("\(model.trend >= 0 ? "+" : "")\(model.trend) this week · best \(model.best)").font(.system(size: 11)).foregroundColor(secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(panel).cornerRadius(10)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current streak").font(.system(size: 12)).foregroundColor(secondary)
                    Text("\(model.streak) days").font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    Text("Score ≥80").font(.system(size: 11)).foregroundColor(secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(panel).cornerRadius(10)
            }
            VStack(spacing: 0) {
                component("Model fit", model.modelFitPoints, 50)
                component("Context discipline", model.contextPoints, 35)
                component("Cost hygiene", model.costPoints, 15)
                metric("Right model · recoverable", "\(Fmt.pct(model.rightModelPct)) · \(Fmt.money(model.recoverableUSD))")
                metric("Context / turn · churn", "\(Fmt.tokens(model.contextPerTurn)) · \(Fmt.pct(model.churn))")
                metric("Context share · cache hit", "\(Fmt.pct(model.contextShare)) · \(Fmt.pct(model.cacheHitPct))")
            }
            Text("Cache hits are reported, not scored.").font(.system(size: 11)).foregroundColor(secondary)
            if compact {
                Text("Use Sonnet for routine work; reserve Opus for hard problems.").font(.system(size: 12)).foregroundColor(secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(panel).cornerRadius(8)
                Button("Open full Scoreboard", action: openFull).buttonStyle(MissionButton())
            } else {
                if !model.sparkScores.isEmpty {
                    Text("Recent score history").font(.system(size: 13, weight: .semibold))
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(model.sparkScores.enumerated()), id: \.offset) { _, value in
                            RoundedRectangle(cornerRadius: 3).fill(cyan.opacity(0.7)).frame(height: max(1, CGFloat(value) * 0.7))
                                .accessibilityLabel("Score \(value)")
                        }
                    }.frame(height: 70, alignment: .bottom)
                    Text("Last \(model.sparkScores.count) recorded days · score out of 100").font(.system(size: 11)).foregroundColor(secondary)
                }
                Text("Badges").font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(model.badges, id: \.name) { badge in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(badge.name, systemImage: badge.earned ? "checkmark.circle" : "circle").font(.system(size: 12, weight: .medium))
                            Text(badge.detail).font(.system(size: 11)).foregroundColor(secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(panel).cornerRadius(10).opacity(badge.earned ? 1 : 0.6)
                    }
                }
                if !model.offenders.isEmpty {
                    Text("Opus on routine work").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(model.offenders.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label).font(.system(size: 12))
                            Text("\(item.reason) · \(Fmt.money(item.opusUSD)) → \(Fmt.money(item.sonnetUSD)) · save \(Fmt.money(item.savingsUSD))").font(.system(size: 11)).foregroundColor(secondary)
                        }
                    }
                }
                if !model.bloated.isEmpty {
                    Text("Heaviest context per turn").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(model.bloated.enumerated()), id: \.offset) { _, item in
                        metric(item.label, "\(Fmt.tokens(item.contextPerTurn))/turn · \(Fmt.money(item.costUSD))")
                    }
                }
            }
        }
    }
    private func component(_ text: String, _ value: Double, _ maxValue: Double) -> some View {
        metric(text, "\(Int(value.rounded())) / \(Int(maxValue))")
    }
    private func metric(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(name).foregroundColor(secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.system(size: 12)).padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(secondary.opacity(0.16)).frame(height: 1) }
    }
}
