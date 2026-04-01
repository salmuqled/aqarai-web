/// Shared number/location parsing for property-style forms ([AddPropertyPage], [AuctionRequestPage]).
String normalizeDigitsForPropertyForm(String input) {
  const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

  var s = input.trim();
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
  }
  return s.replaceAll(RegExp(r'[^\d\.\-]'), '');
}

int parsePropertyInt(String text) =>
    int.tryParse(normalizeDigitsForPropertyForm(text)) ?? 0;

double parsePropertyDouble(String text) =>
    double.tryParse(normalizeDigitsForPropertyForm(text)) ?? 0;

/// Stable slug for governorate/area search codes (same rules as AddPropertyPage).
String propertyLocationCode(String s) {
  var v = s.trim().toLowerCase();
  v = v.replaceAll(RegExp(r'\s+'), '_');
  v = v.replaceAll('-', '_');
  v = v.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
  v = v.replaceAll(RegExp(r'_+'), '_');
  v = v.replaceAll(RegExp(r'^_+|_+$'), '');
  return v;
}
