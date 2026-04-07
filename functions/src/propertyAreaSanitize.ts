/**
 * Firestore triggers: repair broken `areaAr` / `area` on properties (e.g. "-", em dash, empty).
 * Order: areaEn → Arabic (reverse of areaArToEn) or slug via code map; then areaCode / area_id → Arabic.
 * Does not overwrite valid fields; does not write placeholders; leaves doc unchanged if nothing can be inferred.
 */
import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v1";
import { FieldValue } from "firebase-admin/firestore";

import { areaArToEn, propertyLocationCode } from "./invoice/invoicePdfAreaEn";

const AREA_CODE_TO_AR: Record<string, string> = (() => {
  const m: Record<string, string> = {};
  for (const [ar, en] of Object.entries(areaArToEn)) {
    const code = propertyLocationCode(en && en.length > 0 ? en : ar);
    if (!code) continue;
    if (m[code] === undefined) {
      m[code] = ar;
    }
  }
  return m;
})();

function isBrokenAreaField(v: unknown): boolean {
  if (v === undefined || v === null) return true;
  const s = String(v).trim();
  if (s.length === 0) return true;
  if (s === "-") return true;
  if (s === "\u2014" || s === "\u2013" || s === "\u2212") return true; // — – −
  return false;
}

function englishLabelToArabic(enRaw: string): string | null {
  const t = enRaw.trim().toLowerCase();
  if (!t) return null;
  for (const [ar, en] of Object.entries(areaArToEn)) {
    if (en.trim().toLowerCase() === t) return ar;
  }
  return null;
}

function arabicFromCodeRaw(codeRaw: string): {
  arabic: string | null;
  unknownCode: boolean;
} {
  const trimmed = codeRaw.trim();
  if (!trimmed) return { arabic: null, unknownCode: false };
  const normalized = propertyLocationCode(trimmed);
  if (!normalized) {
    return { arabic: null, unknownCode: true };
  }
  const ar = AREA_CODE_TO_AR[normalized];
  if (!ar) {
    return { arabic: null, unknownCode: true };
  }
  return { arabic: ar, unknownCode: false };
}

/**
 * Resolve Arabic area from document fields (same priority as app sanitizer intent).
 */
function resolveArabicFromDoc(d: admin.firestore.DocumentData): {
  value: string | null;
  unknownCodeRaw: string | null;
} {
  const areaEnStr =
    d.areaEn != null && d.areaEn !== undefined ? String(d.areaEn) : "";

  if (!isBrokenAreaField(areaEnStr)) {
    const fromEn = englishLabelToArabic(areaEnStr);
    if (fromEn) {
      return { value: fromEn, unknownCodeRaw: null };
    }
    const fromEnAsSlug = arabicFromCodeRaw(areaEnStr);
    if (fromEnAsSlug.arabic) {
      return { value: fromEnAsSlug.arabic, unknownCodeRaw: null };
    }
  }

  const codeRaw =
    d.areaCode != null && String(d.areaCode).trim() !== ""
      ? String(d.areaCode).trim()
      : d.area_id != null && String(d.area_id).trim() !== ""
        ? String(d.area_id).trim()
        : "";

  if (codeRaw) {
    const { arabic, unknownCode } = arabicFromCodeRaw(codeRaw);
    if (arabic) {
      return { value: arabic, unknownCodeRaw: null };
    }
    if (unknownCode) {
      return { value: null, unknownCodeRaw: codeRaw };
    }
  }

  return { value: null, unknownCodeRaw: null };
}

async function maybeSanitizeProperty(
  snap: admin.firestore.DocumentSnapshot,
  eventType: "create" | "update"
): Promise<void> {
  const data = snap.data();
  if (!data) return;

  const needAreaAr = isBrokenAreaField(data.areaAr);
  const needArea = isBrokenAreaField(data.area);

  if (!needAreaAr && !needArea) return;

  const { value: resolved, unknownCodeRaw } = resolveArabicFromDoc(data);

  if (unknownCodeRaw) {
    functions.logger.warn("Unknown areaCode detected", {
      propertyId: snap.id,
      areaCode: unknownCodeRaw,
      normalized: propertyLocationCode(unknownCodeRaw),
      eventType,
    });
  }

  const updates: Record<string, unknown> = {};

  if (needAreaAr && resolved) {
    updates.areaAr = resolved;
    functions.logger.info("propertyAreaSanitize: fixed areaAr", {
      propertyId: snap.id,
      eventType,
      newAreaAr: resolved,
    });
  }

  if (needArea) {
    if (resolved) {
      updates.area = resolved;
      functions.logger.info("propertyAreaSanitize: fixed area", {
        propertyId: snap.id,
        eventType,
        newArea: resolved,
      });
    } else if (!needAreaAr && !isBrokenAreaField(data.areaAr)) {
      updates.area = String(data.areaAr).trim();
      functions.logger.info("propertyAreaSanitize: fixed area from areaAr", {
        propertyId: snap.id,
        eventType,
      });
    }
  }

  if (Object.keys(updates).length === 0) return;

  updates.updatedAt = FieldValue.serverTimestamp();
  await snap.ref.update(updates);
}

export const onPropertyAreaSanitizeCreate = functions
  .region("us-central1")
  .firestore.document("properties/{propertyId}")
  .onCreate(async (snap, context) => {
    void context;
    await maybeSanitizeProperty(snap, "create");
  });

export const onPropertyAreaSanitizeUpdate = functions
  .region("us-central1")
  .firestore.document("properties/{propertyId}")
  .onUpdate(async (change, context) => {
    void context;
    await maybeSanitizeProperty(change.after, "update");
  });
