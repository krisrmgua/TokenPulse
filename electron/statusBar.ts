import { nativeImage } from "electron";
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
    // Menu bar always pastel; in-app uses bright (see UI tint helpers).
    pastelBarColors: true,
    themedProviderLogos: prefs.themedProviderLogos,
  };

  if (s.meters.length > 0) {
    return s.meters.map((m) => {
      const pct = Math.max(0, Math.min(100, Math.round(m.percentLeft)));
      const label =
        m.id === "session" || /5.?h/i.test(m.label)
          ? "5H"
          : /week/i.test(m.label)
            ? "W"
            : /pro|included|allowance/i.test(m.label)
              ? s.id === "grokbot"
                ? "W"
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
  if (s.id === "openai") {
    const balLine = s.lines.find((l) => /balance/i.test(l.label));
    if (balLine) {
      const n = Number(balLine.value.replace(/[^0-9.]/g, ""));
      metrics.push({
        label: "B",
        value: Number.isFinite(n) ? barMoney(n) : balLine.value.replace(/\s/g, ""),
        color: Number.isFinite(n)
          ? tintBalanceUSD(n, colorOpts)
          : tintSpendUSD(0, s.id, colorOpts, "month"),
      });
    }
  }
  if (s.todayUSD !== undefined && sp.showDailyInBar) {
    metrics.push({
      label: "D",
      value: barMoney(s.todayUSD),
      color: tintSpendUSD(s.todayUSD, s.id, colorOpts, "day"),
    });
  }
  if (s.monthUSD !== undefined && sp.showMonthlyInBar) {
    metrics.push({
      label: "M",
      value: barMoney(s.monthUSD),
      color: tintSpendUSD(s.monthUSD, s.id, colorOpts, "month"),
    });
  }
  return metrics;
}

/** Compose distinct per-provider capsules as one Retina PNG for the tray. */
export async function createStatusBarImage(
  blocks: StatusBlock[],
  prefs: Prefs,
): Promise<Electron.NativeImage> {
  if (blocks.length === 0) return nativeImage.createEmpty();
  await warmStatusBarIcons(
    blocks.map((b) => b.id),
    prefs.themedProviderLogos,
  );
  const { png, scaleFactor } = renderStatusBarPng(blocks, prefs);
  if (png.length === 0) return nativeImage.createEmpty();
  return nativeImage.createFromBuffer(png, { scaleFactor });
}
