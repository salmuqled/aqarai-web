import 'package:flutter/foundation.dart';

/// سياق يُمرَّر لـ Cloud Function [sendPersonalizedNotifications] لمن بلا `preferredArea`.
@immutable
class PersonalizedTrendingPayload {
  const PersonalizedTrendingPayload({
    required this.trendingAreaAr,
    required this.trendingAreaEn,
    required this.dominantPropertyKind,
  });

  final String trendingAreaAr;
  final String trendingAreaEn;
  final String dominantPropertyKind;
}
