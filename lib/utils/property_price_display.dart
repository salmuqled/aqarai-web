/// UI-only: how to label a listing price (suffix after amount).
/// [serviceType] is primary; [priceType] applies only when [serviceType] is `rent`.
enum DisplayPriceType {
  full,
  daily,
  monthly,
}

DisplayPriceType resolveDisplayPriceType({
  required String? serviceType,
  required String? priceType,
}) {
  final s = (serviceType ?? '').trim().toLowerCase();
  final p = (priceType ?? '').trim().toLowerCase();

  if (s == 'sale' || s == 'exchange') {
    return DisplayPriceType.full;
  }

  if (s == 'rent') {
    if (p == 'daily') return DisplayPriceType.daily;
    if (p == 'monthly') return DisplayPriceType.monthly;
  }

  return DisplayPriceType.full;
}

String priceSuffix(DisplayPriceType type, bool isAr) {
  switch (type) {
    case DisplayPriceType.daily:
      return isAr ? ' / ليلة' : ' / night';
    case DisplayPriceType.monthly:
      return isAr ? ' / شهر' : ' / month';
    case DisplayPriceType.full:
      return '';
  }
}
