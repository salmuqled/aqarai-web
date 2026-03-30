import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/system_alert.dart';
import 'package:aqarai_app/services/system_alerts_service.dart';

/// Lists [system_alerts] with severity colors and mark-read actions.
class AdminSystemAlertsSection extends StatelessWidget {
  const AdminSystemAlertsSection({
    super.key,
    required this.loc,
    required this.isAr,
    required this.alerts,
    this.streamError = false,
  });

  final AppLocalizations loc;
  final bool isAr;
  final List<SystemAlert> alerts;
  final bool streamError;

  @override
  Widget build(BuildContext context) {
    final unread = alerts.where((a) => !a.read).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                loc.adminSystemAlertsTitle,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Colors.blueGrey.shade900,
                ),
              ),
            ),
            if (unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.shade700,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  loc.adminSystemAlertsUnread(unread),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        if (streamError) ...[
          const SizedBox(height: 8),
          Text(
            isAr ? 'تعذّر تحميل التنبيهات.' : 'Could not load alerts.',
            style: TextStyle(color: Colors.red.shade800, fontSize: 13),
          ),
        ],
        const SizedBox(height: 10),
        if (alerts.isEmpty && !streamError)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                loc.adminSystemAlertsEmpty,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              ),
            ),
          )
        else
          ...alerts.map((a) => _AlertTile(loc: loc, isAr: isAr, alert: a)),
      ],
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({
    required this.loc,
    required this.isAr,
    required this.alert,
  });

  final AppLocalizations loc;
  final bool isAr;
  final SystemAlert alert;

  Color get _accent =>
      alert.isCritical ? Colors.red.shade700 : Colors.deepOrange.shade800;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: _accent.withValues(alpha: 0.45), width: 1.4),
      ),
      color: alert.isCritical ? Colors.red.shade50 : Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 10),
              child: Icon(
                alert.isCritical ? Icons.error_outline : Icons.warning_amber_rounded,
                color: _accent,
                size: 26,
              ),
            ),
            if (!alert.read)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.title(isAr),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Colors.blueGrey.shade900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    alert.message(isAr),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: Colors.blueGrey.shade800,
                    ),
                  ),
                ],
              ),
            ),
            if (!alert.read)
              TextButton(
                onPressed: () async {
                  try {
                    await SystemAlertsService.markAsRead(alert.id);
                  } catch (_) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(loc.adminControlCenterFailed),
                      ),
                    );
                  }
                },
                child: Text(loc.adminSystemAlertsMarkRead),
              ),
          ],
        ),
      ),
    );
  }
}
