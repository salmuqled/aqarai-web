/// When the listing is a rent chalet (eligible for the booking product on details).
///
/// [PropertyDetailsPage] combines this with role: guests see the full booking surface;
/// owner and admin see [OwnerBookingTools] / [PropertyDetailsAdminControls] instead.
bool canShowBookingUI(Map<String, dynamic> data) {
  final serviceType =
      (data['serviceType'] ?? '').toString().trim().toLowerCase();
  final type = (data['type'] ?? '').toString().trim().toLowerCase();

  return serviceType == 'rent' && type == 'chalet';
}
