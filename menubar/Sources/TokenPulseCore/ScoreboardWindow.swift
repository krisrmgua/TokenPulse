import AppKit
import SwiftUI

/// Everything the scoreboard renders. Built from eff + rollup + history.
struct ScoreboardModel {
    let score: Int
    let grade: String
    let modelFitPoints: Double   // /50
    let contextPoints: Double    // /35
    let costPoints: Double       // /15
    let rightModelPct: Double
    let recoverableUSD: Double
    let contextPerTurn: Double
    let churn: Double
    let contextShare: Double
    let cacheHitPct: Double
    let offenders: [ModelFitOffender]
    let bloated: [BloatedSession]
    let badges: [Badge]
    let sparkScores: [Int]
    let streak: Int
    let best: Int
    let trend: Int

    static func build(eff: EfficiencyResult, rollup: Rollup, history: History) -> ScoreboardModel {
        ScoreboardModel(
            score: eff.score, grade: eff.grade,
            modelFitPoints: eff.modelFitPoints, contextPoints: eff.contextPoints,
            costPoints: eff.costPoints,
            rightModelPct: eff.modelFit.rightModelPct, recoverableUSD: eff.modelFit.recoverableUSD,
            contextPerTurn: eff.context.contextPerTurnMedian, churn: eff.context.churn,
            contextShare: eff.context.contextCostShare, cacheHitPct: eff.cacheHitPct,
            offenders: eff.modelFit.offenders, bloated: eff.context.bloated,
            badges: Achievements.badges(eff: eff, rollup: rollup, history: history),
            sparkScores: history.snapshots.suffix(30).map(\.score),
            streak: history.streak(threshold: 80), best: history.personalBest,
            trend: history.trend7d())
    }
}

struct ScoreboardView: View {
    let m: ScoreboardModel

    var body: some View {
        ScrollView { MissionScoreboardView(model: m).padding(18) }
            .frame(width: 780, height: 700)
            .foregroundColor(Color(red: 0.929, green: 0.961, blue: 1))
            .background(Color(red: 0.055, green: 0.098, blue: 0.161))
            .preferredColorScheme(.dark)
    }
}

/// Owns the scoreboard NSWindow so it survives past the menu action.
final class ScoreboardController {
    private var window: NSWindow?

    func show(_ model: ScoreboardModel) {
        let host = NSHostingView(rootView: ScoreboardView(m: model))
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 700),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "TokenPulse — Efficiency Scoreboard"
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.contentView = host
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Offscreen render to PNG for verification.
    static func renderPNG(_ model: ScoreboardModel, to path: String) {
        let host = NSHostingView(rootView: ScoreboardView(m: model))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 700)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }
}
