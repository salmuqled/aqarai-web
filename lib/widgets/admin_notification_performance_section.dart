import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/services/admin_analytics_service.dart';

int _convInt(dynamic v) {
  if (v is int) return v;
  return int.tryParse('$v') ?? 0;
}

({int totalConv, double weightedRate, QueryDocumentSnapshot<Map<String, dynamic>>? bestDoc})
    _rollupNotificationConversions(
  Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
) {
  var totalConv = 0;
  var totalSent = 0;
  QueryDocumentSnapshot<Map<String, dynamic>>? bestDoc;
  var bestRate = -1.0;
  var bestSentForTie = 0;

  for (final d in docs) {
    final m = d.data();
    final sent = _convInt(m['sentCount']);
    final cc = _convInt(m['conversionCount']);
    totalConv += cc;
    if (sent > 0) totalSent += sent;
    final rate = sent > 0 ? cc / sent : 0.0;
    if (sent > 0) {
      if (rate > bestRate ||
          (rate == bestRate && sent > bestSentForTie)) {
        bestRate = rate;
        bestDoc = d;
        bestSentForTie = sent;
      }
    }
  }

  final weightedRate = totalSent > 0 ? totalConv / totalSent : 0.0;
  return (
    totalConv: totalConv,
    weightedRate: weightedRate,
    bestDoc: bestDoc,
  );
}

/// قسم لوحة الأدمن: أداء الإشعارات (إرسال / نقر / معدل + آخر 5 حملات).
class AdminNotificationPerformanceSection extends StatelessWidget {
  const AdminNotificationPerformanceSection({
    super.key,
    required this.analytics,
    required this.isAr,
  });

  final AdminAnalyticsService analytics;
  final bool isAr;

  static String _firestoreErrorMessage(Object? error, bool isAr) {
    final s = error?.toString() ?? '';
    if (s.contains('permission-denied') ||
        s.contains('Missing or insufficient permissions')) {
      return isAr
          ? 'رفض Firestore: تأكد من نشر قواعد firestore.rules الحالية (تشمل notification_learning) ومن صلاحية admin ثم سجّل الخروج وأعد الدخول.'
          : 'Firestore permission denied: deploy latest firestore.rules (includes notification_learning), ensure admin claim, sign out and back in.';
    }
    return s;
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? '📊 أداء الإشعارات' : '📊 Notification performance',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isAr
                  ? 'يُحدَّث من سجلات الإرسال والنقر (بدون استعلامات ثقيلة).'
                  : 'Updates from send logs and tap tracking (lightweight reads).',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 14),
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: analytics.watchNotificationTotals(),
              builder: (context, totSnap) {
                if (totSnap.hasError) {
                  return Text(
                    _firestoreErrorMessage(totSnap.error, isAr),
                    style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                  );
                }
                final d = totSnap.data?.data();
                final totalSent = d != null ? _asInt(d['totalSent']) : 0;
                final totalClicks = d != null ? _asInt(d['totalClicks']) : 0;
                final rate =
                    totalSent > 0 ? (totalClicks / totalSent * 100) : 0.0;
                final rateStr = totalSent > 0
                    ? '${rate.toStringAsFixed(1)}%'
                    : (isAr ? '—' : '—');

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        _MetricChip(
                          label: isAr ? 'إجمالي المرسل' : 'Total sent',
                          value: '$totalSent',
                          icon: Icons.send_outlined,
                        ),
                        _MetricChip(
                          label: isAr ? 'إجمالي النقرات' : 'Total taps',
                          value: '$totalClicks',
                          icon: Icons.touch_app_outlined,
                        ),
                        _MetricChip(
                          label: isAr ? 'معدل النقر' : 'Tap rate',
                          value: rateStr,
                          icon: Icons.percent_outlined,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      isAr ? '🧠 رؤى التعلّم' : '🧠 Learning insights',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isAr
                          ? 'أوزان مساهمة في درجة التنبؤ (0–50٪ لكل عامل). تُحدَّث آلياً كل 6 ساعات من سجلات الإشعارات — لا إرسال تلقائي.'
                          : 'Weights added to the prediction score (0–50% each). Auto-updated every 6h from logs — no auto-send.',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: analytics.watchNotificationLearning(),
                      builder: (context, learnSnap) {
                        if (learnSnap.hasError) {
                          return Text(
                            _firestoreErrorMessage(learnSnap.error, isAr),
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 12,
                            ),
                          );
                        }
                        if (learnSnap.connectionState ==
                                ConnectionState.waiting &&
                            !learnSnap.hasData) {
                          return const SizedBox(
                            height: 32,
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final docs = learnSnap.data?.docs ?? [];
                        final sorted = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(
                          docs,
                        );
                        if (sorted.isEmpty) {
                          return Text(
                            isAr
                                ? 'لا توجد أوزان بعد — تظهر بعد أول تشغيل لمهمة التعلّم على الخادم.'
                                : 'No weights yet — appears after the first scheduled learning run.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          );
                        }
                        final order = [
                          'hasEmoji',
                          'hasArea',
                          'hasUrgency',
                          'shortText',
                        ];
                        sorted.sort((a, b) {
                          final ia = order.indexOf(a.id);
                          final ib = order.indexOf(b.id);
                          if (ia < 0 && ib < 0) {
                            return a.id.compareTo(b.id);
                          }
                          if (ia < 0) return 1;
                          if (ib < 0) return -1;
                          return ia.compareTo(ib);
                        });
                        return Column(
                          children: sorted.map((doc) {
                            final m = doc.data();
                            final w = m['weight'];
                            final weight = w is num ? w.toDouble() : 0.0;
                            final pct = (weight * 100).clamp(0, 50);
                            final samples = _asInt(m['samples']);
                            final label = _learningFactorLabel(doc.id, isAr);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.trending_up,
                                    size: 16,
                                    color: Colors.deepPurple.shade700,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '+${pct.toStringAsFixed(0)}%',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.deepPurple.shade800,
                                    ),
                                  ),
                                  if (samples > 0) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      '· n=$samples',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isAr
                          ? '💰 تحويلات الإشعارات (صفقات)'
                          : '💰 Notification conversions (deals)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isAr
                          ? 'يُسجَّل عند إنشاء صفقة إذا ضغط المالك على إشعاراً خلال 48 ساعة.'
                          : 'Recorded when a deal is created if the owner tapped a push within 48h.',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: analytics.watchNotificationLogsForConversions(),
                      builder: (context, convSnap) {
                        if (convSnap.hasError) {
                          return Text(
                            _firestoreErrorMessage(convSnap.error, isAr),
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 12,
                            ),
                          );
                        }
                        if (convSnap.connectionState ==
                                ConnectionState.waiting &&
                            !convSnap.hasData) {
                          return const SizedBox(
                            height: 32,
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final rollup = _rollupNotificationConversions(
                          convSnap.data?.docs ?? [],
                        );
                        final best = rollup.bestDoc;
                        final bestM = best?.data();
                        final bestTitle =
                            (bestM?['title'] ?? '—').toString().trim();
                        final bestSent = bestM != null
                            ? _convInt(bestM['sentCount'])
                            : 0;
                        final bestCc = bestM != null
                            ? _convInt(bestM['conversionCount'])
                            : 0;
                        final bestDocRate = bestSent > 0 ? bestCc / bestSent : 0.0;
                        final bestRatePct =
                            (bestDocRate * 100).toStringAsFixed(2);
                        final portfolioPct =
                            (rollup.weightedRate * 100).toStringAsFixed(2);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 14,
                              runSpacing: 8,
                              children: [
                                _MetricChip(
                                  label: isAr ? 'إجمالي التحويلات' : 'Conversions',
                                  value: '${rollup.totalConv}',
                                  icon: Icons.payments_outlined,
                                ),
                                _MetricChip(
                                  label: isAr
                                      ? 'معدل التحويل (محفظة)'
                                      : 'Portfolio conv. rate',
                                  value: '$portfolioPct%',
                                  icon: Icons.analytics_outlined,
                                ),
                              ],
                            ),
                            if (best != null && bestSent > 0) ...[
                              const SizedBox(height: 10),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8F5E9),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.green.shade200,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        isAr
                                            ? 'أفضل إشعار تحويلاً (من آخر السجلات)'
                                            : 'Best converting (recent logs)',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.green.shade900,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        bestTitle,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        isAr
                                            ? 'تحويلات: $bestCc · مرسل: $bestSent · معدل: $bestRatePct%'
                                            : 'Conv: $bestCc · sent: $bestSent · rate: $bestRatePct%',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ] else
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  isAr
                                      ? 'لا بيانات تحويل كافية في آخر السجلات.'
                                      : 'Not enough conversion data in recent logs.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isAr
                          ? '🏆 أفضل نسخة (أحدث حملة A/B)'
                          : '🏆 Best performing variant (latest A/B)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: analytics.watchNotificationLogsForAb(),
                      builder: (context, abSnap) {
                        if (abSnap.hasError) {
                          return Text(
                            _firestoreErrorMessage(abSnap.error, isAr),
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 12,
                            ),
                          );
                        }
                        if (abSnap.connectionState == ConnectionState.waiting &&
                            !abSnap.hasData) {
                          return const SizedBox(
                            height: 36,
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final best = AdminAnalyticsService.getBestNotificationVariant(
                          abSnap.data?.docs ?? [],
                        );
                        if (best == null) {
                          return Text(
                            isAr
                                ? 'لا توجد حملة A/B بعد (أو لا توجد نسختان في آخر السجلات).'
                                : 'No A/B campaign yet (or fewer than 2 variants in recent logs).',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          );
                        }
                        final ctrPct = (best.ctr * 100).toStringAsFixed(1);
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF8E1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.amber.shade200),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  best.variantText,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    height: 1.3,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  isAr
                                      ? 'CTR: $ctrPct% · مرسل: ${best.sentCount} · ${best.variantId}'
                                      : 'CTR: $ctrPct% · sent: ${best.sentCount} · ${best.variantId}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        isAr
                            ? 'دقة التنبؤ (قبل الإرسال): غير مُتتبَّعة بعد — تحتاج تسجيل التنبؤ ومقارنته بالـ CTR الفعلي.'
                            : 'Prediction accuracy (pre-send): not tracked yet — needs logging predictions vs actual CTR.',
                        style: TextStyle(
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isAr ? 'آخر 5 إشعارات' : 'Last 5 notifications',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: analytics.watchRecentNotificationLogs(),
                      builder: (context, logSnap) {
                        if (logSnap.hasError) {
                          return Text(
                            _firestoreErrorMessage(logSnap.error, isAr),
                            style: TextStyle(
                              color: Colors.red.shade800,
                              fontSize: 12,
                            ),
                          );
                        }
                        if (logSnap.connectionState ==
                                ConnectionState.waiting &&
                            !logSnap.hasData) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final docs = logSnap.data?.docs ?? [];
                        if (docs.isEmpty) {
                          return Text(
                            isAr
                                ? 'لا توجد سجلات بعد.'
                                : 'No notification logs yet.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade700,
                            ),
                          );
                        }
                        final dateFmt = DateFormat.yMMMd(
                          isAr ? 'ar' : 'en',
                        );
                        return Column(
                          children: docs.map((doc) {
                            final m = doc.data();
                            final title =
                                (m['title'] ?? '—').toString().trim();
                            final type = (m['type'] ?? '').toString();
                            final sent = _asInt(m['sentCount']);
                            final clicks = _asInt(m['clickCount']);
                            final variantId =
                                (m['variantId'] ?? '').toString().trim();
                            final ts = m['createdAt'];
                            String when = '—';
                            if (ts is Timestamp) {
                              when = dateFmt.format(ts.toDate());
                            }
                            final ctrLine = sent > 0
                                ? ' · CTR ${(clicks / sent * 100).toStringAsFixed(1)}%'
                                : '';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.grey.shade200,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '$when · $type · $sent ${isAr ? "جهاز" : "devices"}'
                                        '${variantId.isNotEmpty ? ' · $variantId' : ''}'
                                        '$ctrLine',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _learningFactorLabel(String id, bool isAr) {
  switch (id) {
    case 'hasEmoji':
      return isAr ? 'الرموز التعبيرية' : 'Emoji';
    case 'hasArea':
      return isAr ? 'ذكر المنطقة' : 'Area in text';
    case 'hasUrgency':
      return isAr ? 'إلحاح (🔥 / 📈)' : 'Urgency (🔥 / 📈)';
    case 'shortText':
      return isAr ? 'نص أقصر' : 'Shorter copy';
    default:
      return id;
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 100, maxWidth: 160),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFE3F2FD),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.shade100),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.blue.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.blueGrey.shade800,
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.shade900,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
