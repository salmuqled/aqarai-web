import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/models/auction/auction_log_entry.dart';
import 'package:aqarai_app/services/auction/auction_log_service.dart';

/// Latest audit log lines for the auction.
class LogsSection extends StatelessWidget {
  const LogsSection({
    super.key,
    required this.auctionId,
    required this.isArabic,
  });

  final String auctionId;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat.yMMMd().add_Hms();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'السجل' : 'Logs',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<AuctionLogEntry>>(
              stream: AuctionLogService.watchLogsForAuction(
                auctionId,
                limit: 50,
              ),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('${snap.error}',
                      style: const TextStyle(color: Colors.red));
                }
                if (!snap.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                final logs = snap.data!;
                if (logs.isEmpty) {
                  return Text(
                    isArabic ? 'لا سجلات' : 'No logs',
                    style: TextStyle(color: Colors.grey.shade600),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: logs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = logs[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        e.action,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${e.performedBy} · ${fmt.format(e.timestamp.toLocal())}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
