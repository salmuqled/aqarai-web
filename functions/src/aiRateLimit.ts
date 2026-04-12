/**
 * Per-user rolling minute rate limits for AI callables (Firestore-backed).
 * Admin callers (custom claim admin === true) skip limits for operational testing.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

const COLLECTION = "ai_call_rate_limits";

export type AiRateLimitKind =
  | "agent_analyze"
  | "agent_compose"
  | "agent_rank"
  | "agent_rank_compose"
  | "agent_find_similar"
  | "assistant_chat";

/** Max invocations per UID per rolling clock minute (epoch minute). */
const LIMITS: Record<AiRateLimitKind, number> = {
  agent_analyze: 30,
  agent_compose: 30,
  agent_rank: 80,
  agent_rank_compose: 30,
  agent_find_similar: 25,
  assistant_chat: 30,
};

const LIMIT_MESSAGE =
  "Too many AI requests. Please wait a minute and try again. / طلبات كثيرة على المساعد، انتظر دقيقة وحاول مرة ثانية.";

function counterFields(kind: AiRateLimitKind): { m: string; n: string } {
  return { m: `${kind}_minute`, n: `${kind}_count` };
}

export async function assertAiRateLimit(
  db: admin.firestore.Firestore,
  request: { auth?: { uid?: string; token?: Record<string, unknown> } },
  kind: AiRateLimitKind
): Promise<void> {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
  }
  if (request.auth.token?.admin === true) {
    return;
  }

  const uid = request.auth.uid;
  const limit = LIMITS[kind];
  const { m: fieldM, n: fieldN } = counterFields(kind);
  const minuteBucket = Math.floor(Date.now() / 60000);
  const ref = db.collection(COLLECTION).doc(uid);

  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const data = snap.exists ? (snap.data() as Record<string, unknown>) : {};
      const prevM = data[fieldM];
      const prevN = data[fieldN];
      const sameWindow =
        typeof prevM === "number" && prevM === minuteBucket && typeof prevN === "number" && prevN >= 0;
      const nextCount = sameWindow ? prevN + 1 : 1;

      if (nextCount > limit) {
        console.warn("[aiRateLimit] limit exceeded", { kind, uid, limit, count: nextCount, minuteBucket });
        throw new HttpsError("resource-exhausted", LIMIT_MESSAGE);
      }

      tx.set(
        ref,
        {
          [fieldM]: minuteBucket,
          [fieldN]: nextCount,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
  } catch (e) {
    if (e instanceof HttpsError) {
      throw e;
    }
    console.error("[aiRateLimit] transaction error", kind, e);
    throw new HttpsError(
      "unavailable",
      "Rate limit check failed. Try again shortly. / تعذر التحقق من الحد، حاول بعد قليل."
    );
  }
}
