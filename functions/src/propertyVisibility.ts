import type { DocumentData } from "firebase-admin/firestore";

/**
 * Must match Dart [listingDataIsPubliclyDiscoverable] and Firestore [propertyPublicDiscovery].
 * No `status` or `type`.
 */
export function isPropertyPublicMarketplaceVisible(d: DocumentData): boolean {
  if (d.approved !== true) return false;
  if (d.hiddenFromPublic !== false) return false;
  const cat = String(d.listingCategory ?? "").trim();
  if (cat === "chalet") return true;
  if (cat === "normal") return d.isActive === true;
  return false;
}

/** Normal listing eligible for wanted matching (same as marketplace normal slice). */
export function isNormalListingMarketplaceVisible(d: DocumentData): boolean {
  return (
    d.approved === true &&
    d.hiddenFromPublic === false &&
    d.listingCategory === "normal" &&
    d.isActive === true
  );
}
