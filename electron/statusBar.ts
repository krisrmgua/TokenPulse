import type { NativeImage } from "electron";
import { isStacked } from "./barDesign";
import { barMoney } from "./format";
import { tintBalanceUSD, tintRemainingPct, tintSpendUSD } from "./spendTint";
import { renderStatusBarPng, warmStatusBarIcons } from "./statusBarRender";
import type { StatusBlock, StatusMetric } from "./statusBarTypes";
import {
  PROVIDER_ORDER,
  type Prefs,
  type SourceId,
  type SourceSnapshot,
} from "./types";

export type { StatusBlock, StatusMetric } from "./statusBarTypes";
export { renderStatusBarPng, setArtworkRoot, warmStatusBarIcons } from "./statusBarRender";

export function blocksFromSources(sources: SourceSnapshot[], prefs: Prefs): StatusBlock[] {
  const byId = new Map(sources.map((s) => [s.id, s]));
  const out: StatusBlock[] = [];
  for (const id of PROVIDER_ORDER) {
    const s = byId.get(id);
    if (!s || !s.enabled || !s.showInTray) continue;
    const sp = prefs.sources[id];
    const metrics = metricsFor(s, sp, prefs);
    if (metrics.length === 0) continue;
    out.push({
      id,
      metrics,
      stale: s.status === "stale",
      allowanceEmpty: metrics.some((m) => m.percent !== undefined && m.percent <= 0),
      design: sp.barDesign,
      sharedPill: sp.sharedPill,
    });
  }
  return out;
}

function metricsFor(
  s: SourceSnapshot,
  sp: Prefs["sources"][SourceId],
  prefs: Prefs,
): StatusMetric[] {
  const colorOpts = {
    spendColorsEnabled: prefs.spendColorsEnabled,
    pastelBarColors: prefs.pastelBarColors,
    themedProviderLogos: prefs.themedProviderLogos,
  };

  if (s.meters.length > 0) {
    return s.meters.map((m) => {
      const pct = Math.max(0, Math.min(100, Math.round(m.percentLeft)));
      const label =
        m.id === "session" || /5.?h/i.test(m.label)
          ? "5"
          : /week/i.test(m.label)
            ? "W"
            : /pro|included|allowance/i.test(m.label)
              ? s.id === "grokbot"
                ? "W"
                : s.id === "cursor" && (sp.sharedPill || sp.barDesign !== "baseline")
                  ? "M"
                  : "Pro"
              : m.label.slice(0, 3);
      return {
        label,
        value: `${pct}%`,
        percent: pct,
        color: tintRemainingPct(pct, colorOpts),
      };
    });
  }

  const metrics: StatusMetric[] = [];
  if (s.id === "openai" && sp.showBalanceInBar) {
    const balLine = s.lines.find((l) => /balance/i.test(l.label));
    const n = balLine ? moneyNumber(balLine.value) : undefined;
    metrics.push({
      label: "B",
      value: n === undefined ? "—" : barMoney(n),
      color:
        n === undefined
          ? [206, 218, 232]
          : tintBalanceUSD(n, colorOpts),
    });
  }
  // Compact stack shows every spend figure unless this source can hide them.
  // OpenAI can hide D, M, or B on any style.
  const forceBoth = !sp.sharedPill && isStacked(sp.barDesign) && s.id !== "openai";
  if (s.todayUSD !== undefined && (forceBoth || sp.showDailyInBar)) {
    metrics.push({
      label: "D",
      value: barMoney(s.todayUSD),
      color: tintSpendUSD(s.todayUSD, s.id, colorOpts, "day"),
    });
  }
  if (s.monthUSD !== undefined && (forceBoth || sp.showMonthlyInBar)) {
    metrics.push({
      label: "M",
      value: barMoney(s.monthUSD),
      color: tintSpendUSD(s.monthUSD, s.id, colorOpts, "month"),
    });
  }
  return metrics;
}

function moneyNumber(raw: string): number | undefined {
  const n = Number(raw.replace(/[$,\s]/g, ""));
  return Number.isFinite(n) ? n : undefined;
}

/** Compose distinct per-provider capsules as one Retina PNG for the tray. */
export async function createStatusBarImage(
  blocks: StatusBlock[],
  prefs: Prefs,
): Promise<NativeImage> {
  const { nativeImage } = await import("electron");
  if (blocks.length === 0) return nativeImage.createEmpty();
  await warmStatusBarIcons(
    blocks.map((b) => b.id),
    prefs.themedProviderLogos,
  );
  const { png, scaleFactor } = renderStatusBarPng(blocks, prefs);
  if (png.length === 0) return nativeImage.createEmpty();
  return nativeImage.createFromBuffer(png, { scaleFactor });
}
