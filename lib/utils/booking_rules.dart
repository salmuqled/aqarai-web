import 'package:aqarai_app/utils/google_maps_link.dart';

/// When the listing supports **night-by-night** booking on the server
/// (`createBooking`): daily chalet **or** daily apartment rent with access fields.
///
/// Mirrors `functions/src/chalet_booking.ts` (`resolveDailyRentBookableProperty`).
bool canShowBookingUI(Map<String, dynamic> data) {
  final serviceType =
      (data['serviceType'] ?? '').toString().trim().toLowerCase();
  final type = (data['type'] ?? '').toString().trim().toLowerCase();
  if (serviceType != 'rent') return false;

  if (type == 'chalet') {
    // Server parity: missing/invalid `chaletMode` defaults to "daily".
    final rawMode = (data['chaletMode'] ?? '').toString().trim().toLowerCase();
    final effectiveMode = rawMode.isEmpty
        ? 'daily'
        : (rawMode == 'daily' || rawMode == 'monthly' || rawMode == 'sale'
            ? rawMode
            : 'daily');
    return effectiveMode == 'daily';
  }

  if (type == 'apartment') {
    final rt = (data['rentalType'] ?? '').toString().trim().toLowerCase();
    final pt = (data['priceType'] ?? '').toString().trim().toLowerCase();
    final isDaily = rt == 'daily' || pt == 'daily';
    if (!isDaily) return false;
    final maps = (data['dailyRentMapsLink'] ?? '').toString().trim();
    final phoneDigits =
        (data['dailyRentContactPhone'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    if (maps.isEmpty || !GoogleMapsLink.looksValid(maps)) return false;
    if (phoneDigits.length < 5) return false;
    return true;
  }

  return false;
}
