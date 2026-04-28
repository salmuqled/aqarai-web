/**
 * HTTPS bridge for in-app MyFatoorah WebView: MyFatoorah [ExecutePayment]
 * requires [http/https] [CallBackUrl] and [ErrorUrl]; the native app is driven
 * via [aqarai://] deep links. This page loads after checkout and immediately
 * redirects the WebView to the same [aqarai://] shape the app already handles.
 */
import { onRequest } from "firebase-functions/v2/https";

const ALLOWED_S = new Set<string>([
  "payment/feature/success",
  "payment/feature/error",
  "payment/auction/success",
  "payment/auction/error",
  "payment/success",
  "payment/error",
]);

function htmlEscape(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * [s] = path after [aqarai://] (e.g. [payment/feature/success]).
 * Other query keys are passed through to the deep link (e.g. [paymentId] from MyFatoorah).
 */
function buildAqaraiFromExpressQuery(
  q: Record<string, unknown> | undefined
): { ok: true; link: string } | { ok: false } {
  if (!q || typeof q !== "object") {
    return { ok: false };
  }
  const sRaw = q.s;
  const s0 =
    typeof sRaw === "string"
      ? sRaw.trim()
      : Array.isArray(sRaw) && typeof sRaw[0] === "string"
        ? sRaw[0].trim()
        : "";
  if (!s0 || !ALLOWED_S.has(s0)) {
    return { ok: false };
  }
  const out = new URLSearchParams();
  for (const [k, v] of Object.entries(q)) {
    if (k === "s") continue;
    if (Array.isArray(v)) v.forEach((x) => out.append(k, String(x)));
    else if (v != null && String(v).length > 0) out.append(k, String(v));
  }
  const qs = out.toString();
  return { ok: true, link: `aqarai://${s0}${qs ? `?${qs}` : ""}` };
}

export const myFatoorahAppReturn = onRequest(
  { region: "us-central1", cors: true },
  (req, res) => {
    if (req.method === "OPTIONS") {
      res.status(204).send("");
      return;
    }
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.status(405).type("text/plain").send("Method Not Allowed");
      return;
    }
    const parsed = buildAqaraiFromExpressQuery(
      req.query as Record<string, unknown> | undefined
    );
    if (!parsed.ok) {
      res
        .status(400)
        .type("text/html; charset=utf-8")
        .send(
          "<!DOCTYPE html><html><body>Invalid return parameters. You can close this page.</body></html>"
        );
      return;
    }
    const link = parsed.link;
    const linkJs = JSON.stringify(link);
    if (req.method === "HEAD") {
      res.status(200).end();
      return;
    }
    res
      .status(200)
      .type("text/html; charset=utf-8")
      .send(`<!DOCTYPE html>
<html><head>
<meta charset="utf-8"/>
<meta http-equiv="refresh" content="0;url=${htmlEscape(link)}"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>العودة إلى التطبيق</title>
</head><body>
<p>العودة إلى AqarAi… / Returning to the app…</p>
<script>window.location.replace(${linkJs});</script>
</body></html>`);
  }
);
