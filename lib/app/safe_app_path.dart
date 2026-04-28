/// Guards [GoRouter] redirects from open redirects / external URLs.
String? safeAppPath(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (!t.startsWith('/') || t.startsWith('//')) return null;
  return t;
}
