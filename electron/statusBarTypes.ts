import type { BarDesign } from "./barDesign";
import type { SourceId } from "./types";

export interface StatusMetric {
  label: string;
  value: string;
  percent?: number;
  color: [number, number, number];
}

export interface StatusBlock {
  id: SourceId;
  metrics: StatusMetric[];
  stale: boolean;
  allowanceEmpty: boolean;
  design: BarDesign;
  /** Join the single shared pill. Missing means this block keeps its own capsule. */
  sharedPill?: boolean;
}
