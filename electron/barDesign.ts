/** Menu-bar capsule layouts — numbers match Swift StatusBarDesign. */
export type BarDesign =
  | "divider"
  | "rings"
  | "baseline"
  | "stack"
  | "focus"
  | "lanes"
  | "segments";

export const BAR_DESIGNS: {
  id: BarDesign;
  number: number;
  name: string;
  spendOk: boolean;
}[] = [
  { id: "divider", number: 1, name: "Divider capsule", spendOk: true },
  { id: "rings", number: 2, name: "Twin gauges", spendOk: false },
  { id: "baseline", number: 3, name: "Baseline meters", spendOk: false },
  { id: "stack", number: 4, name: "Compact stack", spendOk: true },
  { id: "focus", number: 5, name: "Focus capsule", spendOk: false },
  { id: "lanes", number: 6, name: "Stacked tracks", spendOk: false },
  { id: "segments", number: 7, name: "Segmented lanes", spendOk: false },
];

export function barDesignTitle(id: BarDesign): string {
  const d = BAR_DESIGNS.find((x) => x.id === id);
  return d ? `${d.number} · ${d.name}` : id;
}

export function barDesignsFor(spendOnly: boolean): typeof BAR_DESIGNS {
  return spendOnly ? BAR_DESIGNS.filter((d) => d.spendOk) : BAR_DESIGNS;
}

export function resolveBarDesign(id: BarDesign, spendOnly: boolean): BarDesign {
  if (!spendOnly) return id;
  return id === "stack" ? "stack" : "divider";
}

export function isStacked(id: BarDesign): boolean {
  return id === "stack" || id === "lanes" || id === "segments";
}
