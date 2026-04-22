/// Validates and extracts coordinates from Google Maps share URLs.
///
/// Used by the Add Property form for chalet rentals, where a map link is
/// required so the booking-confirmation email can deep-link the customer
/// to the property's exact location.
///
/// Accepted URL shapes (matches the form-validation spec):
///   - https://www.google.com/maps/...        // full web link
///   - https://maps.google.com/...            // alternate full link
///   - https://maps.app.goo.gl/...            // modern share shortener
///
/// Coordinate extraction is intentionally best-effort:
///   - Short links (`maps.app.goo.gl`) resolve to coords only after a
///     network redirect, which we can't do synchronously from a form
///     validator. In that case the link is saved without lat/lng.
///   - For full web links, we read the two patterns Google embeds in
///     share URLs (`@lat,lng` and `!3d…!4d…`), plus legacy query-param
///     forms (`q=`, `ll=`, `query=`).
///
/// The form saves whatever we extract — extraction failure is NOT a
/// validation failure. This matches the product decision: "if extraction
/// fails, still allow saving link".
library;

/// Thin namespace so we can call [GoogleMapsLink.looksValid] at the call
/// site instead of leaking two free-floating functions into the file.
class GoogleMapsLink {
  GoogleMapsLink._();

  /// True when the string contains one of the two substrings the spec
  /// accepts. Trims + lowercases so copy-paste with a trailing newline or
  /// `HTTPS://` casing still passes.
  static bool looksValid(String? raw) {
    if (raw == null) return false;
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return false;
    return s.contains('google.com/maps') || s.contains('maps.app.goo.gl');
  }

  /// Best-effort `(lat, lng)` extraction. Returns null when the URL is a
  /// short-link or otherwise doesn't carry explicit coordinates.
  ///
  /// Checked in priority order:
  ///   1. `!3d<lat>!4d<lng>` — Google's place-pin payload; when present,
  ///      this is the most accurate signal of the intended destination.
  ///   2. `@<lat>,<lng>,<zoom>z` — camera target embedded in the path.
  ///      Reliable for "share → copy link" output on web.
  ///   3. `?q=`, `?ll=`, `?query=` — legacy / api=1 query forms.
  static ({double lat, double lng})? tryExtractLatLng(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    // (1) Place-pin payload `!3d<lat>!4d<lng>` — strongest signal.
    final pin = RegExp(r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)').firstMatch(s);
    if (pin != null) {
      final p = _parsePair(pin.group(1), pin.group(2));
      if (p != null) return p;
    }

    // (2) Camera target `@<lat>,<lng>`.
    final at = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(s);
    if (at != null) {
      final p = _parsePair(at.group(1), at.group(2));
      if (p != null) return p;
    }

    // (3) Legacy / api=1 query params (`?q=`, `&ll=`, `&query=`).
    final qp = RegExp(
      r'[?&](?:q|ll|query)=(-?\d+\.\d+),(-?\d+\.\d+)',
    ).firstMatch(s);
    if (qp != null) {
      final p = _parsePair(qp.group(1), qp.group(2));
      if (p != null) return p;
    }

    return null;
  }

  /// Range-checks a lat/lng pair. Returns null on any parse failure or
  /// out-of-range value, so callers can safely use `??` to skip saving.
  static ({double lat, double lng})? _parsePair(String? a, String? b) {
    if (a == null || b == null) return null;
    final lat = double.tryParse(a);
    final lng = double.tryParse(b);
    if (lat == null || lng == null) return null;
    if (!lat.isFinite || !lng.isFinite) return null;
    if (lat < -90 || lat > 90) return null;
    if (lng < -180 || lng > 180) return null;
    return (lat: lat, lng: lng);
  }
}
