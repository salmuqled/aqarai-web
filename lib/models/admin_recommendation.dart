import 'package:flutter/foundation.dart';

/// Typed string values for [AdminRecommendation.type] (UI maps to colors).
abstract final class AdminRecommendationType {
  static const String success = 'success';
  static const String warning = 'warning';
  static const String danger = 'danger';
}

abstract final class AdminRecommendationPriority {
  static const String high = 'high';
  static const String medium = 'medium';
  static const String low = 'low';
}

abstract final class AdminRecommendationImpact {
  static const String high = 'high';
  static const String medium = 'medium';
  static const String low = 'low';
}

abstract final class AdminRecommendationTrend {
  static const String up = 'up';
  static const String down = 'down';
  static const String stable = 'stable';
}

/// One actionable insight for admins; [onAction] runs only when the user taps the button.
@immutable
class AdminRecommendation {
  const AdminRecommendation({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.type,
    required this.confidence,
    required this.priority,
    required this.impact,
    required this.trend,
    required this.canSendNotification,
    this.value,
    this.change,
    this.notificationTitle,
    this.notificationBody,
    this.onAction,
    this.onPersonalizedAction,
  });

  final String title;
  final String description;
  final String actionLabel;

  /// One of [AdminRecommendationType.success], `.warning`, `.danger`.
  final String type;

  /// 0–1; surfaced in UI as a percentage.
  final double confidence;

  /// One of [AdminRecommendationPriority.high], `.medium`, `.low`.
  final String priority;

  /// One of [AdminRecommendationImpact.high], `.medium`, `.low`.
  final String impact;

  /// Primary metric in native units (e.g. AI share 0–1, conversion 0–1). Optional for non-metric cards.
  final double? value;

  /// Delta vs previous period in the same units as [value]; null → UI hides change row.
  final double? change;

  /// One of [AdminRecommendationTrend.up], `.down`, `.stable`.
  final String trend;

  /// When true, primary action opens notification preview (never auto-sends).
  final bool canSendNotification;

  /// Draft FCM title/body when [canSendNotification] is true; may be edited in preview.
  final String? notificationTitle;

  /// Draft FCM body when [canSendNotification] is true.
  final String? notificationBody;

  /// Manual action only — never invoked automatically.
  final VoidCallback? onAction;

  /// ثانوي: فتح معاينة الإرسال المخصّص (عند [canSendNotification] مع محرك ذكي مزدوج).
  final VoidCallback? onPersonalizedAction;
}
