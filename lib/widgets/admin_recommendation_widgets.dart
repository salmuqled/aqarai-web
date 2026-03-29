import 'package:flutter/material.dart';

import 'package:aqarai_app/models/admin_recommendation.dart';

/// Background + border tint for a recommendation [type].
Color _cardColorForType(String type) {
  switch (type) {
    case AdminRecommendationType.danger:
      return const Color(0xFFFFEBEE);
    case AdminRecommendationType.warning:
      return const Color(0xFFFFF3E0);
    case AdminRecommendationType.success:
    default:
      return const Color(0xFFE8F5E9);
  }
}

Color _borderColorForType(String type) {
  switch (type) {
    case AdminRecommendationType.danger:
      return const Color(0xFFE57373);
    case AdminRecommendationType.warning:
      return const Color(0xFFFFB74D);
    case AdminRecommendationType.success:
    default:
      return const Color(0xFF81C784);
  }
}

Color _priorityBadgeColor(String priority) {
  switch (priority) {
    case AdminRecommendationPriority.high:
      return const Color(0xFFC62828);
    case AdminRecommendationPriority.medium:
      return const Color(0xFFEF6C00);
    case AdminRecommendationPriority.low:
    default:
      return const Color(0xFF757575);
  }
}

String _priorityLabel(String priority, bool isAr) {
  switch (priority) {
    case AdminRecommendationPriority.high:
      return isAr ? 'عالية' : 'HIGH';
    case AdminRecommendationPriority.medium:
      return isAr ? 'متوسطة' : 'MEDIUM';
    case AdminRecommendationPriority.low:
    default:
      return isAr ? 'منخفضة' : 'LOW';
  }
}

String _impactLabel(String impact, bool isAr) {
  switch (impact) {
    case AdminRecommendationImpact.high:
      return isAr ? 'عالٍ' : 'High';
    case AdminRecommendationImpact.medium:
      return isAr ? 'متوسط' : 'Medium';
    case AdminRecommendationImpact.low:
    default:
      return isAr ? 'منخفض' : 'Low';
  }
}

Widget _trendGlyph(String trend) {
  final Color color;
  final String glyph;
  switch (trend) {
    case AdminRecommendationTrend.up:
      color = const Color(0xFF2E7D32);
      glyph = '↑';
      break;
    case AdminRecommendationTrend.down:
      color = const Color(0xFFC62828);
      glyph = '↓';
      break;
    case AdminRecommendationTrend.stable:
    default:
      color = const Color(0xFF757575);
      glyph = '→';
      break;
  }
  return Text(
    glyph,
    style: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w800,
      color: color,
      height: 1,
    ),
  );
}

String? _changeDisplayText(AdminRecommendation rec, bool isAr) {
  final d = rec.change;
  if (d == null) return null;
  final pp = d * 100;
  final sign = pp >= 0 ? '+' : '';
  final v = '$sign${pp.toStringAsFixed(1)}%';
  return isAr ? '$v من أمس' : '$v vs yesterday';
}

String? _valueDisplayText(AdminRecommendation rec) {
  final v = rec.value;
  if (v == null) return null;
  return '${(v * 100).toStringAsFixed(1)}%';
}

/// Single recommendation with manual [ElevatedButton] (calls [rec.onAction] only on tap).
Widget buildRecommendationCard(
  AdminRecommendation rec, {
  required bool isAr,
}) {
  final bg = _cardColorForType(rec.type);
  final border = _borderColorForType(rec.type);
  final pct = (rec.confidence.clamp(0.0, 1.0) * 100).round();
  final valueLine = _valueDisplayText(rec);
  final changeLine = _changeDisplayText(rec, isAr);
  final badgeColor = _priorityBadgeColor(rec.priority);

  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: border.withValues(alpha: 0.65)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  rec.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: badgeColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  isAr
                      ? 'أولوية: ${_priorityLabel(rec.priority, true)}'
                      : 'Priority: ${_priorityLabel(rec.priority, false)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
          if (valueLine != null || changeLine != null) ...[
            const SizedBox(height: 8),
            if (valueLine != null)
              Text(
                isAr ? 'القيمة: $valueLine' : 'Value: $valueLine',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade900,
                ),
              ),
            if (changeLine != null) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _trendGlyph(rec.trend),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      changeLine,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
          const SizedBox(height: 8),
          Text(
            rec.description,
            style: TextStyle(
              fontSize: 14,
              height: 1.35,
              color: Colors.grey.shade900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isAr
                ? 'التأثير: ${_impactLabel(rec.impact, true)}'
                : 'Impact: ${_impactLabel(rec.impact, false)}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          if (rec.canSendNotification) ...[
            const SizedBox(height: 4),
            Text(
              isAr
                  ? 'يفتح معاينة ثم إرسال يدوي فقط — لا إرسال تلقائي.'
                  : 'Opens a preview; send is manual only — never automatic.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ],
          const SizedBox(height: 14),
          if (rec.canSendNotification && rec.onPersonalizedAction != null) ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: rec.onAction,
                    child: Text(isAr ? 'إرسال عام' : 'Broadcast'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: rec.onPersonalizedAction,
                    child: Text(isAr ? 'إرسال مخصّص' : 'Personalized'),
                  ),
                ),
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: rec.onAction,
                    child: Text(rec.actionLabel),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            isAr ? 'ثقة $pct%' : 'Confidence $pct%',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade800,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Section wrapper: title + list of [buildRecommendationCard]s.
Widget buildRecommendationsSection(
  List<AdminRecommendation> recs, {
  required bool isAr,
}) {
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
            isAr ? '🧠 محرك القرار' : '🧠 Smart decision engine',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isAr
                ? 'اقتراحات يدوية؛ التنبيهات تمر بمعاينة ثم إرسال بعد موافقتك.'
                : 'Manual suggestions; pushes use preview then send only after you confirm.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 14),
          ...recs.map((r) => buildRecommendationCard(r, isAr: isAr)),
        ],
      ),
    ),
  );
}
