/**
 * إجراءات أدمن حساسة عبر Callable Functions (تنفيذ حقيقي مع تحقق من الصلاحية).
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

import { audienceUidFilter } from "./notificationAudience";
import { isValidFcmTokenString } from "./fcmToken";

function assertAdmin(request: { auth?: { token: Record<string, unknown> } }) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  if (request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
}

const MAX_TITLE = 200;
const MAX_BODY = 500;
const MAX_SOURCE_LEN = 120;
const MAX_VARIANT_ID_LEN = 40;
const MIN_AB_VARIANTS = 2;
const MAX_AB_VARIANTS = 5;
/** FCM يسمح بحد أقصى 500 توكن لكل طلب متعدد */
const FCM_MULTICAST_LIMIT = 500;

function parseOptionalSource(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const s = raw.trim();
  if (s.length === 0) return null;
  return s.length > MAX_SOURCE_LEN ? s.slice(0, MAX_SOURCE_LEN) : s;
}

type FactorKey = "hasEmoji" | "hasUrgency" | "hasArea" | "shortText";

type FactorsMap = Record<FactorKey, boolean>;

const FACTOR_KEYS: FactorKey[] = [
  "hasEmoji",
  "hasArea",
  "hasUrgency",
  "shortText",
];

const DEFAULT_SHORT_THRESHOLD = 160;

function hasEmojiRunes(text: string): boolean {
  for (let i = 0; i < text.length; ) {
    const c = text.codePointAt(i)!;
    if ((c >= 0x1f300 && c <= 0x1faff) || (c >= 0x2600 && c <= 0x27bf)) {
      return true;
    }
    i += c > 0xffff ? 2 : 1;
  }
  return false;
}

function computeFactorsFromText(
  title: string,
  body: string,
  areaHint: string | null,
  shortThreshold: number
): FactorsMap {
  const text = `${title}\n${body}`;
  return {
    hasEmoji: hasEmojiRunes(text),
    hasArea: !!(areaHint && areaHint.length > 0 && text.includes(areaHint)),
    hasUrgency: text.includes("🔥") || text.includes("📈"),
    shortText: text.length > 0 && text.length <= shortThreshold,
  };
}

function parsePartialFactors(raw: unknown): Partial<FactorsMap> | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const out: Partial<FactorsMap> = {};
  for (const k of FACTOR_KEYS) {
    if (typeof o[k] === "boolean") {
      out[k] = o[k] as boolean;
    }
  }
  return Object.keys(out).length > 0 ? out : null;
}

function mergeFactors(
  client: Partial<FactorsMap> | null,
  server: FactorsMap
): FactorsMap {
  if (!client) return server;
  return {
    hasEmoji:
      typeof client.hasEmoji === "boolean" ? client.hasEmoji : server.hasEmoji,
    hasArea:
      typeof client.hasArea === "boolean" ? client.hasArea : server.hasArea,
    hasUrgency:
      typeof client.hasUrgency === "boolean"
        ? client.hasUrgency
        : server.hasUrgency,
    shortText:
      typeof client.shortText === "boolean"
        ? client.shortText
        : server.shortText,
  };
}

function parsePredictionMeta(raw: unknown): {
  predictedScore: number | null;
  factors: Partial<FactorsMap> | null;
  variantId: string | null;
} {
  if (!raw || typeof raw !== "object") {
    return { predictedScore: null, factors: null, variantId: null };
  }
  const o = raw as Record<string, unknown>;
  const predictedScore =
    typeof o.predictedScore === "number" && !Number.isNaN(o.predictedScore)
      ? o.predictedScore
      : null;
  const factors = parsePartialFactors(o.factors);
  const variantId =
    typeof o.variantId === "string" && o.variantId.trim().length > 0
      ? o.variantId.trim().slice(0, MAX_VARIANT_ID_LEN)
      : null;
  return { predictedScore, factors, variantId };
}

function parseAutoDecisionLogId(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const s = raw.trim();
  if (s.length < 10 || s.length > 128) return null;
  if (!/^[\w-]+$/.test(s)) return null;
  return s;
}

function parseOptionalAreaHint(data: Record<string, unknown>): string | null {
  const ta =
    typeof data.trendingAreaAr === "string" ? data.trendingAreaAr.trim() : "";
  if (ta.length > 0) return ta.length > 200 ? ta.slice(0, 200) : ta;
  const pm = data.predictionMeta;
  if (pm && typeof pm === "object") {
    const a = (pm as Record<string, unknown>).areaHint;
    if (typeof a === "string" && a.trim().length > 0) {
      const s = a.trim();
      return s.length > 200 ? s.slice(0, 200) : s;
    }
  }
  return null;
}

async function writeNotificationLogAndIncrementTotals(args: {
  notificationId: string;
  title: string;
  body: string;
  type: "broadcast" | "personalized";
  sentCount: number;
  source: string | null;
  areaHint?: string | null;
  predictedScore?: number | null;
  clientFactors?: Partial<FactorsMap> | null;
  variantId?: string | null;
  shortTextThreshold?: number;
  autoDecisionLogId?: string | null;
}): Promise<void> {
  const db = admin.firestore();
  const batch = db.batch();
  const logRef = db.collection("notification_logs").doc(args.notificationId);
  const shortTh = args.shortTextThreshold ?? DEFAULT_SHORT_THRESHOLD;
  const hint = args.areaHint?.trim() || null;
  const serverF = computeFactorsFromText(
    args.title,
    args.body,
    hint,
    shortTh
  );
  const factors = mergeFactors(args.clientFactors ?? null, serverF);

  const logPayload: Record<string, unknown> = {
    title: args.title,
    body: args.body,
    type: args.type,
    sentCount: args.sentCount,
    clickCount: 0,
    actualCTR: 0,
    conversionCount: 0,
    conversionRate: 0,
    conversionValue: 0,
    factors,
    createdAt: FieldValue.serverTimestamp(),
  };
  if (args.source) logPayload.source = args.source;
  if (args.predictedScore != null) {
    logPayload.predictedScore = args.predictedScore;
  }
  if (args.variantId != null && args.variantId.length > 0) {
    logPayload.variantId = args.variantId;
  }
  batch.set(logRef, logPayload);

  const totRef = db.collection("analytics").doc("notification_totals");
  batch.set(
    totRef,
    {
      totalSent: FieldValue.increment(args.sentCount),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  const decId = args.autoDecisionLogId?.trim();
  if (decId && decId.length >= 10 && decId.length <= 128) {
    const decRef = db.collection("auto_decision_logs").doc(decId);
    batch.update(decRef, { notificationId: args.notificationId });
  }

  await batch.commit();
}

type ParsedAbVariant = {
  variantId: string;
  title: string;
  body: string;
  notificationId: string;
  predictedScore: number | null;
  clientFactors: Partial<FactorsMap> | null;
};

function parseAbVariants(raw: unknown): ParsedAbVariant[] | null {
  if (!Array.isArray(raw)) return null;
  if (raw.length < MIN_AB_VARIANTS || raw.length > MAX_AB_VARIANTS) return null;
  const out: ParsedAbVariant[] = [];
  const seen = new Set<string>();
  const db = admin.firestore();
  for (const item of raw) {
    if (!item || typeof item !== "object") return null;
    const o = item as Record<string, unknown>;
    const variantId =
      typeof o.variantId === "string" ? o.variantId.trim() : "";
    const title = typeof o.title === "string" ? o.title.trim() : "";
    const body = typeof o.body === "string" ? o.body.trim() : "";
    if (
      variantId.length === 0 ||
      variantId.length > MAX_VARIANT_ID_LEN ||
      title.length === 0 ||
      body.length === 0
    ) {
      return null;
    }
    if (title.length > MAX_TITLE || body.length > MAX_BODY) return null;
    if (seen.has(variantId)) return null;
    seen.add(variantId);
    const predictedScore =
      typeof o.predictedScore === "number" && !Number.isNaN(o.predictedScore)
        ? o.predictedScore
        : null;
    const clientFactors = parsePartialFactors(o.factors);
    out.push({
      variantId,
      title,
      body,
      notificationId: db.collection("notification_logs").doc().id,
      predictedScore,
      clientFactors,
    });
  }
  return out.length >= MIN_AB_VARIANTS ? out : null;
}

function variantTextLine(title: string, body: string): string {
  const s = `${title} — ${body}`;
  return s.length > 600 ? s.slice(0, 600) : s;
}

function medianTextLengthForAb(variants: ParsedAbVariant[]): number {
  if (variants.length === 0) return DEFAULT_SHORT_THRESHOLD;
  const lens = variants.map((v) => `${v.title}\n${v.body}`.length);
  lens.sort((a, b) => a - b);
  const mid = Math.floor(lens.length / 2);
  return lens[mid] ?? DEFAULT_SHORT_THRESHOLD;
}

async function writeAbVariantLogsAndIncrementTotals(args: {
  abCampaignId: string;
  areaHint: string | null;
  shortTextThreshold: number;
  variants: {
    notificationId: string;
    variantId: string;
    title: string;
    body: string;
    sentCount: number;
    predictedScore: number | null;
    clientFactors: Partial<FactorsMap> | null;
  }[];
  source: string | null;
}): Promise<void> {
  const db = admin.firestore();
  const batch = db.batch();
  for (const v of args.variants) {
    const logRef = db.collection("notification_logs").doc(v.notificationId);
    const serverF = computeFactorsFromText(
      v.title,
      v.body,
      args.areaHint,
      args.shortTextThreshold
    );
    const factors = mergeFactors(v.clientFactors ?? null, serverF);
    const logPayload: Record<string, unknown> = {
      title: v.title,
      body: v.body,
      variantId: v.variantId,
      variantText: variantTextLine(v.title, v.body),
      abCampaignId: args.abCampaignId,
      abTest: true,
      type: "broadcast",
      sentCount: v.sentCount,
      clickCount: 0,
      actualCTR: 0,
      conversionCount: 0,
      conversionRate: 0,
      conversionValue: 0,
      factors,
      createdAt: FieldValue.serverTimestamp(),
    };
    if (args.source) logPayload.source = args.source;
    if (v.predictedScore != null) {
      logPayload.predictedScore = v.predictedScore;
    }
    batch.set(logRef, logPayload);
  }
  const totalSent = args.variants.reduce((acc, x) => acc + x.sentCount, 0);
  const totRef = db.collection("analytics").doc("notification_totals");
  batch.set(
    totRef,
    {
      totalSent: FieldValue.increment(totalSent),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  await batch.commit();
}

async function sendMulticastWithCleanup(args: {
  tokens: string[];
  tokenToUid: Map<string, string>;
  title: string;
  body: string;
  data: Record<string, string>;
}): Promise<number> {
  let sent = 0;
  const { tokens, tokenToUid, title, body, data } = args;
  for (let i = 0; i < tokens.length; i += FCM_MULTICAST_LIMIT) {
    const chunk = tokens.slice(i, i + FCM_MULTICAST_LIMIT);
    const response = await admin.messaging().sendEachForMulticast({
      tokens: chunk,
      notification: { title, body },
      data,
    });
    sent += response.successCount;

    const cleanup: Promise<unknown>[] = [];
    response.responses.forEach((res, idx) => {
      if (res.success) return;
      const code = res.error?.code ?? "";
      if (
        code.includes("registration-token-not-registered") ||
        code.includes("invalid-registration-token")
      ) {
        const registrationToken = chunk[idx];
        const uid = tokenToUid.get(registrationToken);
        if (uid) {
          cleanup.push(
            admin
              .firestore()
              .collection("users")
              .doc(uid)
              .update({ fcmToken: FieldValue.delete() })
              .catch(() => undefined)
          );
        }
      }
    });
    await Promise.all(cleanup);
  }
  return sent;
}

/**
 * إرسال إشعار FCM لجميع مستخدمي `users` الذين لديهم `fcmToken` صالح.
 * يدعم نسخة واحدة (title/body) أو مصفوفة variants لاختبار A/B (توزيع بالتناوب على التوكنات).
 * يستخدم sendEachForMulticast (البديل الموصى به لـ sendMulticast في Admin SDK الحديث).
 *
 * FUTURE: وضع تلقائي لاختيار أفضل نسخة — غير مفعّل؛ الإرسال يبقى يدوياً من لوحة الأدمن.
 */
export const sendGlobalNotification = onCall(
  { region: "us-central1" },
  async (request) => {
    assertAdmin(request);

    const source = parseOptionalSource(request.data?.source);
    const abParsed = parseAbVariants(request.data?.variants);
    const reqData = (request.data || {}) as Record<string, unknown>;
    const uidFilter = await audienceUidFilter(reqData.audienceSegment);

    if (abParsed) {
      const abCampaignId = admin.firestore().collection("notification_logs").doc().id;
      const areaHintAb = parseOptionalAreaHint(reqData);
      const shortThAb = medianTextLengthForAb(abParsed);
      const snap = await admin
        .firestore()
        .collection("users")
        .where("fcmToken", "!=", null)
        .get();
      const tokenToUid = new Map<string, string>();
      const tokens: string[] = [];

      for (const doc of snap.docs) {
        if (uidFilter !== null && !uidFilter.has(doc.id)) continue;
        const raw = doc.data()?.fcmToken;
        if (!isValidFcmTokenString(raw)) continue;
        const tok = (raw as string).trim();
        if (tokenToUid.has(tok)) continue;
        tokenToUid.set(tok, doc.id);
        tokens.push(tok);
      }

      const n = abParsed.length;
      const buckets: string[][] = Array.from({ length: n }, () => []);
      tokens.forEach((tok, idx) => {
        buckets[idx % n]!.push(tok);
      });

      if (tokens.length === 0) {
        await writeAbVariantLogsAndIncrementTotals({
          abCampaignId,
          areaHint: areaHintAb,
          shortTextThreshold: shortThAb,
          variants: abParsed.map((v) => ({
            notificationId: v.notificationId,
            variantId: v.variantId,
            title: v.title,
            body: v.body,
            sentCount: 0,
            predictedScore: v.predictedScore,
            clientFactors: v.clientFactors,
          })),
          source,
        });
        return {
          success: true,
          sentCount: 0,
          abCampaignId,
          notificationIds: abParsed.map((v) => v.notificationId),
        };
      }

      const sentPerVariant = Array(n).fill(0) as number[];
      for (let vi = 0; vi < n; vi++) {
        const v = abParsed[vi]!;
        const bucket = buckets[vi]!;
        const data: Record<string, string> = {
          notificationId: v.notificationId,
          variantId: v.variantId,
          abCampaignId,
        };
        const s = await sendMulticastWithCleanup({
          tokens: bucket,
          tokenToUid,
          title: v.title,
          body: v.body,
          data,
        });
        sentPerVariant[vi] = s;
      }

      const sentCount = sentPerVariant.reduce((a, x) => a + x, 0);
      await writeAbVariantLogsAndIncrementTotals({
        abCampaignId,
        areaHint: areaHintAb,
        shortTextThreshold: shortThAb,
        variants: abParsed.map((v, i) => ({
          notificationId: v.notificationId,
          variantId: v.variantId,
          title: v.title,
          body: v.body,
          sentCount: sentPerVariant[i] ?? 0,
          predictedScore: v.predictedScore,
          clientFactors: v.clientFactors,
        })),
        source,
      });

      return {
        success: true,
        sentCount,
        abCampaignId,
        notificationIds: abParsed.map((v) => v.notificationId),
      };
    }

    const title = request.data?.title;
    const body = request.data?.body;

    if (typeof title !== "string" || title.trim().length === 0) {
      throw new HttpsError("invalid-argument", "title is required");
    }
    if (typeof body !== "string" || body.trim().length === 0) {
      throw new HttpsError("invalid-argument", "body is required");
    }
    const t = title.trim();
    const b = body.trim();
    if (t.length > MAX_TITLE || b.length > MAX_BODY) {
      throw new HttpsError(
        "invalid-argument",
        `title max ${MAX_TITLE} chars, body max ${MAX_BODY} chars`
      );
    }

    const notificationId = admin.firestore().collection("notification_logs").doc().id;
    const pred = parsePredictionMeta(request.data?.predictionMeta);
    const areaHintSingle = parseOptionalAreaHint(reqData);
    const autoDecisionLogId = parseAutoDecisionLogId(reqData.autoDecisionLogId);

    const snap = await admin
      .firestore()
      .collection("users")
      .where("fcmToken", "!=", null)
      .get();
    const tokenToUid = new Map<string, string>();
    const tokens: string[] = [];

    for (const doc of snap.docs) {
      if (uidFilter !== null && !uidFilter.has(doc.id)) continue;
      const raw = doc.data()?.fcmToken;
      if (!isValidFcmTokenString(raw)) continue;
      const tok = (raw as string).trim();
      if (tokenToUid.has(tok)) continue;
      tokenToUid.set(tok, doc.id);
      tokens.push(tok);
    }

    if (tokens.length === 0) {
      await writeNotificationLogAndIncrementTotals({
        notificationId,
        title: t,
        body: b,
        type: "broadcast",
        sentCount: 0,
        source,
        areaHint: areaHintSingle,
        predictedScore: pred.predictedScore,
        clientFactors: pred.factors,
        variantId: pred.variantId ?? "broadcast",
        shortTextThreshold: DEFAULT_SHORT_THRESHOLD,
        autoDecisionLogId,
      });
      return { success: true, sentCount: 0, notificationId };
    }

    const sentCount = await sendMulticastWithCleanup({
      tokens,
      tokenToUid,
      title: t,
      body: b,
      data: { notificationId },
    });

    await writeNotificationLogAndIncrementTotals({
      notificationId,
      title: t,
      body: b,
      type: "broadcast",
      sentCount,
      source,
      areaHint: areaHintSingle,
      predictedScore: pred.predictedScore,
      clientFactors: pred.factors,
      variantId: pred.variantId ?? "broadcast",
      shortTextThreshold: DEFAULT_SHORT_THRESHOLD,
      autoDecisionLogId,
    });

    return { success: true, sentCount, notificationId };
  }
);

const FCM_SEND_EACH_LIMIT = 500;

function clampStr(s: string, max: number): string {
  const t = s.trim();
  if (t.length <= max) return t;
  return t.slice(0, max);
}

function emojiForPropertyKind(kind: string): string {
  const k = (kind || "").toLowerCase();
  if (
    k.includes("house") ||
    k.includes("villa") ||
    k.includes("بيت") ||
    k.includes("فيلا")
  ) {
    return "🏠";
  }
  if (
    k.includes("apartment") ||
    k.includes("flat") ||
    k.includes("شق") ||
    k.includes("duplex")
  ) {
    return "🏢";
  }
  if (k.includes("land") || k.includes("أرض") || k.includes("ارض") || k.includes("plot")) {
    return "🌍";
  }
  if (k.includes("chalet") || k.includes("شاليه")) {
    return "🏖️";
  }
  return "📢";
}

function buildPersonalizedNotification(args: {
  preferredArea?: string;
  preferredType?: string;
  trendingAreaAr: string;
  trendingAreaEn: string;
  dominantPropertyKind: string;
  isArabic: boolean;
}): { title: string; body: string } {
  const ta = args.trendingAreaAr.trim();
  const te = args.trendingAreaEn.trim();
  const pa = (args.preferredArea || "").trim();
  const areaAr = pa || ta || "عقارات جديدة";
  const areaEn = pa || te || ta || "new listings";
  const kindHint = (args.preferredType || "").trim() || args.dominantPropertyKind;
  const emoji = emojiForPropertyKind(kindHint);

  if (args.isArabic) {
    return {
      title: clampStr(`${emoji} عقارات جديدة في ${areaAr} تناسبك`, MAX_TITLE),
      body: clampStr(
        `🔥 تصفّح أحدث العروض في ${areaAr} على عقار أي.`,
        MAX_BODY
      ),
    };
  }
  return {
    title: clampStr(`${emoji} New listings in ${areaEn} for you`, MAX_TITLE),
    body: clampStr(`🔥 See the latest offers in ${areaEn} on AqarAi.`, MAX_BODY),
  };
}

/**
 * إشعار مخصّص لكل مستخدم: preferredArea / preferredType من users، مع fallback للاتجاه العام من العميل.
 * إرسال على دفعات (sendEach حتى 500 رسالة لكل دفعة).
 */
export const sendPersonalizedNotifications = onCall(
  { region: "us-central1" },
  async (request) => {
    assertAdmin(request);

    const trendingAreaAr =
      typeof request.data?.trendingAreaAr === "string"
        ? request.data.trendingAreaAr
        : "";
    const trendingAreaEn =
      typeof request.data?.trendingAreaEn === "string"
        ? request.data.trendingAreaEn
        : "";
    const dominantPropertyKind =
      typeof request.data?.dominantPropertyKind === "string"
        ? request.data.dominantPropertyKind
        : "other";
    const isArabic = request.data?.isArabic === true;

    if (trendingAreaAr.length > 200 || trendingAreaEn.length > 200) {
      throw new HttpsError("invalid-argument", "trending area too long");
    }
    if (dominantPropertyKind.length > 80) {
      throw new HttpsError("invalid-argument", "dominantPropertyKind too long");
    }

    const source = parseOptionalSource(request.data?.source);
    const logTitleRaw = request.data?.logTitle;
    const logBodyRaw = request.data?.logBody;
    const logTitle =
      typeof logTitleRaw === "string" && logTitleRaw.trim().length > 0
        ? clampStr(logTitleRaw, MAX_TITLE)
        : isArabic
          ? "إشعار مخصّص"
          : "Personalized notification";
    const logBody =
      typeof logBodyRaw === "string" && logBodyRaw.trim().length > 0
        ? clampStr(logBodyRaw, MAX_BODY)
        : isArabic
          ? "نص يختلف حسب تفضيلات كل مستخدم."
          : "Copy varies per user preferences.";

    const notificationId = admin.firestore().collection("notification_logs").doc().id;

    const snap = await admin
      .firestore()
      .collection("users")
      .where("fcmToken", "!=", null)
      .get();

    type Row = { token: string; uid: string; title: string; body: string };
    const rows: Row[] = [];
    const tokenToUid = new Map<string, string>();
    let skippedNoToken = 0;

    for (const doc of snap.docs) {
      const d = doc.data();
      const raw = d?.fcmToken;
      if (!isValidFcmTokenString(raw)) {
        skippedNoToken++;
        continue;
      }
      const tok = (raw as string).trim();
      if (tokenToUid.has(tok)) continue;
      tokenToUid.set(tok, doc.id);

      const preferredArea =
        typeof d?.preferredArea === "string" ? d.preferredArea : "";
      const preferredType =
        typeof d?.preferredType === "string" ? d.preferredType : "";

      const { title, body } = buildPersonalizedNotification({
        preferredArea,
        preferredType,
        trendingAreaAr,
        trendingAreaEn,
        dominantPropertyKind,
        isArabic,
      });

      rows.push({ token: tok, uid: doc.id, title, body });
    }

    if (rows.length === 0) {
      await writeNotificationLogAndIncrementTotals({
        notificationId,
        title: logTitle,
        body: logBody,
        type: "personalized",
        sentCount: 0,
        source,
        areaHint: trendingAreaAr.trim() || null,
        variantId: "personalized",
        shortTextThreshold: DEFAULT_SHORT_THRESHOLD,
      });
      return {
        success: true,
        sentCount: 0,
        skippedNoToken,
        notificationId,
      };
    }

    const messages: admin.messaging.Message[] = rows.map((r) => ({
      token: r.token,
      notification: { title: r.title, body: r.body },
      data: { notificationId },
    }));

    let sentCount = 0;

    for (let i = 0; i < messages.length; i += FCM_SEND_EACH_LIMIT) {
      const batchMessages = messages.slice(i, i + FCM_SEND_EACH_LIMIT);
      const batchRows = rows.slice(i, i + FCM_SEND_EACH_LIMIT);
      const response = await admin.messaging().sendEach(batchMessages);
      sentCount += response.responses.filter((x) => x.success).length;

      const cleanup: Promise<unknown>[] = [];
      response.responses.forEach((res, idx) => {
        if (res.success) return;
        const code = res.error?.code ?? "";
        if (
          code.includes("registration-token-not-registered") ||
          code.includes("invalid-registration-token")
        ) {
          const registrationToken = batchRows[idx]?.token;
          if (!registrationToken) return;
          const uid = tokenToUid.get(registrationToken);
          if (uid) {
            cleanup.push(
              admin
                .firestore()
                .collection("users")
                .doc(uid)
                .update({ fcmToken: FieldValue.delete() })
                .catch(() => undefined)
            );
          }
        }
      });
      await Promise.all(cleanup);
    }

    await writeNotificationLogAndIncrementTotals({
      notificationId,
      title: logTitle,
      body: logBody,
      type: "personalized",
      sentCount,
      source,
      areaHint: trendingAreaAr.trim() || null,
      variantId: "personalized",
      shortTextThreshold: DEFAULT_SHORT_THRESHOLD,
    });

    return {
      success: true,
      sentCount,
      skippedNoToken,
      notificationId,
    };
  }
);
