import fs from "node:fs";

/** USD per 1M tokens. */
export interface Rate {
  input: number;
  output: number;
  cacheWrite: number;
  cacheRead: number;
}

const BUILTIN_FAMILIES: Record<string, Rate> = {
  opus: { input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5 },
  sonnet: { input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3 },
  haiku: { input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1 },
  fable: { input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1.0 },
  sol: { input: 5.5, output: 33.0, cacheWrite: 6.875, cacheRead: 0.55 },
  terra: { input: 2.2, output: 13.2, cacheWrite: 2.75, cacheRead: 0.22 },
  luna: { input: 0.22, output: 1.32, cacheWrite: 0.275, cacheRead: 0.022 },
};

const BUILTIN_OVERRIDES: Record<string, Rate> = {
  "claude-sonnet-5": { input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2 },
  "gpt-5.4": { input: 2.75, output: 16.5, cacheWrite: 2.75, cacheRead: 0.275 },
  "gpt-5.5": { input: 5.5, output: 33.0, cacheWrite: 5.5, cacheRead: 0.55 },
};

const BUILTIN_FALLBACK: Rate = {
  input: 5,
  output: 25,
  cacheWrite: 6.25,
  cacheRead: 0.5,
};

const FAMILY_DELIMITERS = /[./\-_]/;

/**
 * Same three-tier resolution as the Swift app: longest override substring,
 * then a family codename matched as a whole delimited component, then fallback.
 */
export class Pricing {
  readonly overrides: Record<string, Rate>;
  readonly families: Record<string, Rate>;
  readonly fallback: Rate;
  readonly source: string;

  constructor(candidatePaths: string[] = []) {
    const loaded = loadFromDisk(candidatePaths);
    if (loaded) {
      this.overrides = loaded.overrides;
      this.families = loaded.families;
      this.fallback = loaded.fallback;
      this.source = loaded.path;
    } else {
      this.overrides = BUILTIN_OVERRIDES;
      this.families = BUILTIN_FAMILIES;
      this.fallback = BUILTIN_FALLBACK;
      this.source = "built-in";
    }
  }

  rate(model: string): Rate {
    let best: { len: number; rate: Rate } | undefined;
    for (const [key, rate] of Object.entries(this.overrides)) {
      if (model.includes(key) && (!best || key.length > best.len)) {
        best = { len: key.length, rate };
      }
    }
    if (best) return best.rate;
    const components = new Set(model.toLowerCase().split(FAMILY_DELIMITERS));
    for (const [name, rate] of Object.entries(this.families)) {
      if (components.has(name.toLowerCase())) return rate;
    }
    return this.fallback;
  }

  cost(
    input: number,
    cacheWrite: number,
    cacheRead: number,
    output: number,
    model: string,
  ): number {
    const r = this.rate(model);
    return (
      (input * r.input +
        cacheWrite * r.cacheWrite +
        cacheRead * r.cacheRead +
        output * r.output) /
      1_000_000
    );
  }
}

function parseRate(raw: unknown): Rate | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const d = raw as Record<string, unknown>;
  const nums = [d.input, d.output, d.cache_write, d.cache_read];
  if (!nums.every((n) => typeof n === "number" && Number.isFinite(n))) {
    return undefined;
  }
  return {
    input: d.input as number,
    output: d.output as number,
    cacheWrite: d.cache_write as number,
    cacheRead: d.cache_read as number,
  };
}

function parseTable(raw: unknown): Record<string, Rate> {
  const out: Record<string, Rate> = {};
  if (typeof raw !== "object" || raw === null) return out;
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    const rate = parseRate(v);
    if (rate) out[k] = rate;
  }
  return out;
}

function loadFromDisk(paths: string[]):
  | {
      overrides: Record<string, Rate>;
      families: Record<string, Rate>;
      fallback: Rate;
      path: string;
    }
  | undefined {
  for (const p of paths) {
    let obj: Record<string, unknown>;
    try {
      obj = JSON.parse(fs.readFileSync(p, "utf8")) as Record<string, unknown>;
    } catch {
      continue;
    }
    const overrides = parseTable(obj.models);
    const familiesOnDisk = parseTable(obj.families);
    if (
      Object.keys(overrides).length === 0 &&
      Object.keys(familiesOnDisk).length === 0
    ) {
      continue;
    }
    return {
      overrides,
      families:
        Object.keys(familiesOnDisk).length > 0 ? familiesOnDisk : BUILTIN_FAMILIES,
      fallback: parseRate(obj.default) ?? BUILTIN_FALLBACK,
      path: p,
    };
  }
  return undefined;
}
