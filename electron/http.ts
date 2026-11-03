export const USER_AGENT = "TokenPulse/1.0";

export class SourceError extends Error {
  constructor(
    message: string,
    readonly kind: "auth" | "network" | "http" | "parse" | "setup" = "parse",
    readonly status?: number,
  ) {
    super(message);
  }
}

export interface JsonResponse {
  status: number;
  body: unknown;
}

/** JSON request with a hard timeout. Network failures become SourceError("network"). */
export async function requestJSON(
  url: string,
  init: {
    method?: "GET" | "POST";
    headers?: Record<string, string>;
    body?: unknown;
    timeoutMs?: number;
  } = {},
): Promise<JsonResponse> {
  const headers: Record<string, string> = {
    "User-Agent": USER_AGENT,
    Accept: "application/json",
    ...init.headers,
  };
  let body: string | undefined;
  if (init.body !== undefined) {
    body = JSON.stringify(init.body);
    headers["Content-Type"] = "application/json";
  }
  let res: Response;
  try {
    res = await fetch(url, {
      method: init.method ?? (body ? "POST" : "GET"),
      headers,
      body,
      signal: AbortSignal.timeout(init.timeoutMs ?? 15_000),
    });
  } catch {
    throw new SourceError("Could not reach the service.", "network");
  }
  const text = await res.text().catch(() => "");
  let parsed: unknown = undefined;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = undefined;
    }
  }
  return { status: res.status, body: parsed };
}
