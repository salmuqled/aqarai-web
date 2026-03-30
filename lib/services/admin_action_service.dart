import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/support_ticket.dart';
import 'package:aqarai_app/models/notification_learning_factors.dart';
import 'package:aqarai_app/models/personalized_trending_payload.dart';
import 'package:aqarai_app/services/notification_prediction_service.dart';
import 'package:aqarai_app/services/smart_notification_service.dart';

/// بيانات التنبؤ لحقول `notification_logs` (`predictedScore`, `factors`) — لا تُستخدم للإرسال التلقائي.
class NotificationPredictionLogMeta {
  const NotificationPredictionLogMeta({
    required this.predictedScore,
    required this.factors,
    this.variantId,
    this.trendingAreaAr,
  });

  final double predictedScore;
  final NotificationLearningFactors factors;
  final String? variantId;
  final String? trendingAreaAr;

  Map<String, dynamic> toCallablePredictionMeta() => {
        'predictedScore': predictedScore,
        'factors': factors.toFirestoreMap(),
        if (variantId != null && variantId!.trim().isNotEmpty)
          'variantId': variantId!.trim(),
        if (trendingAreaAr != null && trendingAreaAr!.trim().isNotEmpty)
          'areaHint': trendingAreaAr!.trim(),
      };
}

/// تنفيذ آمن لإجراءات الأدمن عبر Cloud Functions (مع ردود واجهة).
abstract final class AdminActionService {
  static FirebaseFunctions _funcs() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// يرسل إشعارًا لجميع المستخدمين الذين لديهم `fcmToken` في `users/{uid}`.
  /// يعرض حوار تحميل ثم SnackBar نجاح/فشل.
  static Future<void> sendNotification({
    required BuildContext context,
    required String title,
    required String body,
    required bool isAr,
    String? source,
    NotificationPredictionLogMeta? predictionLog,
    String? trendingAreaAr,
    String? audienceSegment,
    String? autoDecisionLogId,
  }) async {
    if (!context.mounted) return;

    // لا نستخدم await هنا — وإلا ننتظر إغلاق الحوار قبل استدعاء الـ Function.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(isAr ? 'جاري الإرسال…' : 'Sending…'),
                ),
              ],
            ),
          ),
        );
      },
    );

    void closeLoading() {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      final callable = _funcs().httpsCallable('sendGlobalNotification');
      final payload = <String, dynamic>{
        'title': title,
        'body': body,
      };
      final s = source?.trim();
      if (s != null && s.isNotEmpty) {
        payload['source'] = s;
      }
      final pl = predictionLog;
      if (pl != null) {
        payload['predictionMeta'] = pl.toCallablePredictionMeta();
      }
      final ta = trendingAreaAr?.trim();
      if (ta != null && ta.isNotEmpty) {
        payload['trendingAreaAr'] = ta;
      }
      final aud = audienceSegment?.trim().toLowerCase();
      if (aud != null && aud.isNotEmpty && aud != 'all') {
        payload['audienceSegment'] = aud;
      }
      final adId = autoDecisionLogId?.trim();
      if (adId != null && adId.isNotEmpty) {
        payload['autoDecisionLogId'] = adId;
      }
      final result = await callable.call<Map<String, dynamic>>(payload);

      closeLoading();
      if (!context.mounted) return;

      final data = result.data;
      final sent = data['sentCount'];
      final count = sent is int ? sent : int.tryParse('$sent') ?? 0;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr
                ? (count == 0
                    ? 'لم يُرسل لأن لا توجد توكنات مسجّلة.'
                    : 'تم إرسال الإشعار ($count جهاز).')
                : (count == 0
                    ? 'No FCM tokens found; nothing sent.'
                    : 'Notification sent ($count devices).'),
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      closeLoading();
      if (!context.mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(_mapFunctionsError(e, isAr)),
        ),
      );
    } catch (e) {
      closeLoading();
      if (!context.mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(
            isAr ? 'فشل الإرسال: $e' : 'Send failed: $e',
          ),
        ),
      );
    }
  }

  /// يضيف وظيفة إرسال مؤجّلة (تنفّذها دالة مجدولة على السيرفر — لا إرسال فوري).
  static Future<void> queueScheduledNotification({
    required BuildContext context,
    required String title,
    required String body,
    required DateTime scheduledAt,
    required bool isAr,
    String? source,
    NotificationPredictionLogMeta? predictionLog,
    String? trendingAreaAr,
    String? audienceSegment,
    String? autoDecisionLogId,
  }) async {
    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(isAr ? 'جاري الجدولة…' : 'Scheduling…'),
                ),
              ],
            ),
          ),
        );
      },
    );

    void closeLoading() {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      final callable = _funcs().httpsCallable('queueScheduledNotification');
      final payload = <String, dynamic>{
        'title': title,
        'body': body,
        'scheduledAtMs': scheduledAt.millisecondsSinceEpoch,
      };
      final s = source?.trim();
      if (s != null && s.isNotEmpty) {
        payload['source'] = s;
      }
      final pl = predictionLog;
      if (pl != null) {
        payload['predictionMeta'] = pl.toCallablePredictionMeta();
      }
      final ta = trendingAreaAr?.trim();
      if (ta != null && ta.isNotEmpty) {
        payload['trendingAreaAr'] = ta;
      }
      final aud = audienceSegment?.trim().toLowerCase();
      if (aud != null && aud.isNotEmpty) {
        payload['audienceSegment'] = aud;
      }
      final adId = autoDecisionLogId?.trim();
      if (adId != null && adId.isNotEmpty) {
        payload['autoDecisionLogId'] = adId;
      }
      await callable.call<Map<String, dynamic>>(payload);
      closeLoading();
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr
                ? 'تم حفظ الجدولة. سيُرسل الإشعار تلقائياً في الوقت المحدد.'
                : 'Scheduled. The push will send automatically at the chosen time.',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      closeLoading();
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(_mapFunctionsError(e, isAr)),
        ),
      );
    } catch (e) {
      closeLoading();
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(
            isAr ? 'فشلت الجدولة: $e' : 'Schedule failed: $e',
          ),
        ),
      );
    }
  }

  /// بث عام بعدة نصوص (A/B): يوزّع المستخدمين على مجموعات على الخادم.
  static Future<void> sendAbBroadcast({
    required BuildContext context,
    required List<SmartNotificationSuggestion> variants,
    required bool isAr,
    String? source,
    Map<String, NotificationPredictionLogMeta>? predictionByCanonicalText,
    String? trendingAreaAr,
    String? audienceSegment,
  }) async {
    if (variants.length < 2) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr ? 'يلزم نسختان على الأقل لاختبار A/B.' : 'Need at least 2 variants for A/B.',
          ),
        ),
      );
      return;
    }

    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    isAr ? 'جاري إرسال اختبار A/B…' : 'Sending A/B broadcast…',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    void closeLoading() {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      final callable = _funcs().httpsCallable('sendGlobalNotification');
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < variants.length; i++) {
        final v = variants[i];
        final id = (v.variantId ?? 'v$i').trim();
        if (id.isEmpty) continue;
        final canonical = NotificationPredictionService.canonicalVariantText(
          v.title,
          v.body,
        );
        final meta = predictionByCanonicalText?[canonical];
        final entry = <String, dynamic>{
          'variantId': id,
          'title': v.title.trim(),
          'body': v.body.trim(),
        };
        if (meta != null) {
          entry['predictedScore'] = meta.predictedScore;
          entry['factors'] = meta.factors.toFirestoreMap();
        }
        list.add(entry);
      }
      if (list.length < 2) {
        closeLoading();
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red.shade800,
            content: Text(
              isAr ? 'بيانات النسخ غير صالحة.' : 'Invalid variant payload.',
            ),
          ),
        );
        return;
      }

      final payload = <String, dynamic>{'variants': list};
      final s = source?.trim();
      if (s != null && s.isNotEmpty) {
        payload['source'] = s;
      }
      final ta = trendingAreaAr?.trim();
      if (ta != null && ta.isNotEmpty) {
        payload['trendingAreaAr'] = ta;
      }
      final aud = audienceSegment?.trim().toLowerCase();
      if (aud != null && aud.isNotEmpty && aud != 'all') {
        payload['audienceSegment'] = aud;
      }
      final result = await callable.call<Map<String, dynamic>>(payload);

      closeLoading();
      if (!context.mounted) return;

      final data = result.data;
      final sent = data['sentCount'];
      final count = sent is int ? sent : int.tryParse('$sent') ?? 0;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr
                ? (count == 0
                    ? 'لم يُرسل لأن لا توجد توكنات مسجّلة.'
                    : 'تم إرسال اختبار A/B ($count جهاز).')
                : (count == 0
                    ? 'No FCM tokens found; nothing sent.'
                    : 'A/B notification sent ($count devices).'),
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      closeLoading();
      if (!context.mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(_mapFunctionsError(e, isAr)),
        ),
      );
    } catch (e) {
      closeLoading();
      if (!context.mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(
            isAr ? 'فشل الإرسال: $e' : 'Send failed: $e',
          ),
        ),
      );
    }
  }

  /// إشعار مخصّص لكل مستخدم (يُبنى على الخادم من `preferredArea` / `preferredType` + اتجاه عام).
  static Future<void> sendPersonalizedNotifications({
    required BuildContext context,
    required PersonalizedTrendingPayload payload,
    required bool isAr,
    String? source,
    String? logTitle,
    String? logBody,
  }) async {
    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(isAr ? 'جاري الإرسال المخصّص…' : 'Sending personalized…'),
                ),
              ],
            ),
          ),
        );
      },
    );

    void closeLoading() {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      final callable = _funcs().httpsCallable('sendPersonalizedNotifications');
      final req = <String, dynamic>{
        'trendingAreaAr': payload.trendingAreaAr,
        'trendingAreaEn': payload.trendingAreaEn,
        'dominantPropertyKind': payload.dominantPropertyKind,
        'isArabic': isAr,
      };
      final src = source?.trim();
      if (src != null && src.isNotEmpty) {
        req['source'] = src;
      }
      final lt = logTitle?.trim();
      if (lt != null && lt.isNotEmpty) {
        req['logTitle'] = lt;
      }
      final lb = logBody?.trim();
      if (lb != null && lb.isNotEmpty) {
        req['logBody'] = lb;
      }
      final result = await callable.call<Map<String, dynamic>>(req);

      closeLoading();
      if (!context.mounted) return;

      final data = result.data;
      final sent = data['sentCount'];
      final count = sent is int ? sent : int.tryParse('$sent') ?? 0;
      final skipped = data['skippedNoToken'];
      final skipN =
          skipped is int ? skipped : int.tryParse('$skipped') ?? 0;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr
                ? (count == 0
                    ? 'لم يُرسل لأن لا توجد توكنات مسجّلة.'
                    : 'تم إرسال إشعارات مخصّصة ($count جهاز، تخطّي بلا توكن: $skipN).')
                : (count == 0
                    ? 'No FCM tokens; nothing sent.'
                    : 'Personalized notifications sent ($count devices, skipped no token: $skipN).'),
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      closeLoading();
      if (!context.mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;

      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(_mapFunctionsError(e, isAr)),
        ),
      );
    } catch (e) {
      closeLoading();
      if (!context.mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(
            isAr ? 'فشل الإرسال: $e' : 'Send failed: $e',
          ),
        ),
      );
    }
  }

  /// Disables the account server-side (Auth + Firestore `users/{uid}` ban fields).
  static Future<void> banUser({
    required BuildContext context,
    required String targetUid,
    required bool isAr,
  }) async {
    if (!context.mounted) return;
    final trimmed = targetUid.trim();
    if (trimmed.isEmpty) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(isAr ? 'جاري الحظر…' : 'Banning user…'),
                ),
              ],
            ),
          ),
        );
      },
    );

    void closeLoading() {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      final callable = _funcs().httpsCallable('banUser');
      await callable.call<Map<String, dynamic>>({'targetUid': trimmed});
      closeLoading();
      if (!context.mounted) return;
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(loc?.banUserSuccess ?? (isAr ? 'تم حظر المستخدم.' : 'User has been banned.')),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      closeLoading();
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(_mapFunctionsError(e, isAr)),
        ),
      );
    } catch (e) {
      closeLoading();
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade800,
          content: Text(
            isAr ? 'فشل الحظر: $e' : 'Ban failed: $e',
          ),
        ),
      );
    }
  }

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Admin-only (Firestore rules). Sets `status` and `updatedAt`.
  static Future<void> updateSupportTicketStatus({
    required String ticketId,
    required String status,
  }) async {
    if (!SupportTicketStatus.isValid(status)) {
      throw ArgumentError('Invalid support ticket status');
    }
    await _firestore.collection('support_tickets').doc(ticketId).update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Admin-only (Firestore rules).
  static Future<void> deleteSupportTicket(String ticketId) async {
    await _firestore.collection('support_tickets').doc(ticketId).delete();
  }

  static String _mapFunctionsError(
    FirebaseFunctionsException e,
    bool isAr,
  ) {
    switch (e.code) {
      case 'permission-denied':
        return isAr
            ? 'لا تملك صلاحية الأدمن.'
            : 'Admin permission denied.';
      case 'unauthenticated':
        return isAr ? 'سجّل الدخول أولاً.' : 'Please sign in.';
      case 'invalid-argument':
        return e.message ?? (isAr ? 'بيانات غير صالحة.' : 'Invalid input.');
      case 'not-found':
        return isAr ? 'المستخدم غير موجود.' : 'User not found.';
      default:
        return e.message ?? e.code;
    }
  }
}
