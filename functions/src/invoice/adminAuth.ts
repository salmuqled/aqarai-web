/**
 * Callable auth: match Firestore rules + Flutter AuthService (boolean or legacy string).
 */
export function isAdminFromCallableAuth(
  auth: { token?: Record<string, unknown> } | undefined
): boolean {
  if (auth == null || auth.token == null) return false;
  const a = auth.token.admin;
  return a === true || a === "true";
}
