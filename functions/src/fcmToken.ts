/** FCM registration tokens must be longer than this (client rule: length > 10). */
export const FCM_TOKEN_MIN_LENGTH = 11;

export function isValidFcmTokenString(raw: unknown): boolean {
  if (typeof raw !== "string") return false;
  return raw.trim().length >= FCM_TOKEN_MIN_LENGTH;
}
