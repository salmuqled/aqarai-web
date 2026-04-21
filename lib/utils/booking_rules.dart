/// When the listing is a *daily* rent chalet — the only category the server
/// actually accepts bookings for.
///
/// Mirrors the gate in `functions/src/chalet_booking.ts#effectiveChaletMode`:
/// `createBooking`, `checkBookingAvailability`, and `finalizeBookingAfterPayment`
/// all reject anything but `chaletMode == "daily"`, so monthly/yearly chalets
/// must not surface the Book-Now UI (the server-rejection path produces a
/// confusing "تعذر إنشاء الحجز" snackbar with no guidance).
///
/// [PropertyDetailsPage] combines this with role: guests see the full booking
/// surface; owner and admin see [OwnerBookingTools] /
/// [PropertyDetailsAdminControls] instead.
bool canShowBookingUI(Map<String, dynamic> data) {
  final serviceType =
      (data['serviceType'] ?? '').toString().trim().toLowerCase();
  final type = (data['type'] ?? '').toString().trim().toLowerCase();
  if (serviceType != 'rent' || type != 'chalet') return false;

  // Server parity: missing/invalid `chaletMode` defaults to "daily".
  final rawMode = (data['chaletMode'] ?? '').toString().trim().toLowerCase();
  final effectiveMode = rawMode.isEmpty
      ? 'daily'
      : (rawMode == 'daily' || rawMode == 'monthly' || rawMode == 'sale'
          ? rawMode
          : 'daily');
  return effectiveMode == 'daily';
}
