import 'package:cloud_firestore/cloud_firestore.dart';

/// Row in [system_alerts] (managed by Cloud Function; admin marks read).
class SystemAlert {
  const SystemAlert({
    required this.id,
    required this.type,
    required this.severity,
    required this.titleEn,
    required this.titleAr,
    required this.messageEn,
    required this.messageAr,
    required this.read,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String type;
  /// `critical` (red) or `warning` (orange).
  final String severity;
  final String titleEn;
  final String titleAr;
  final String messageEn;
  final String messageAr;
  final bool read;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String title(bool isAr) => isAr ? titleAr : titleEn;
  String message(bool isAr) => isAr ? messageAr : messageEn;

  bool get isCritical => severity == 'critical';

  static SystemAlert? fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    if (d == null) return null;
    return SystemAlert(
      id: doc.id,
      type: (d['type'] ?? '').toString(),
      severity: (d['severity'] ?? 'warning').toString(),
      titleEn: (d['titleEn'] ?? '').toString(),
      titleAr: (d['titleAr'] ?? d['titleEn'] ?? '').toString(),
      messageEn: (d['messageEn'] ?? '').toString(),
      messageAr: (d['messageAr'] ?? d['messageEn'] ?? '').toString(),
      read: d['read'] == true,
      createdAt: _ts(d['createdAt']),
      updatedAt: _ts(d['updatedAt']),
    );
  }

  static DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }
}
