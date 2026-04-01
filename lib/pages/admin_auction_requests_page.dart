import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/services/auction/auction_request_service.dart';
import 'package:aqarai_app/services/auth_service.dart';

/// Admin: review `auction_requests` and set approved / rejected (lots created separately).
class AdminAuctionRequestsPage extends StatefulWidget {
  const AdminAuctionRequestsPage({super.key});

  @override
  State<AdminAuctionRequestsPage> createState() =>
      _AdminAuctionRequestsPageState();
}

class _AdminAuctionRequestsPageState extends State<AdminAuctionRequestsPage> {
  Future<bool> _adminGateFuture = AuthService.isAdmin();

  void _retryGate() {
    setState(() => _adminGateFuture = AuthService.isAdmin());
  }

  String _fmtDate(BuildContext context, Timestamp? ts) {
    final loc = Localizations.localeOf(context);
    final dt = ts?.toDate();
    if (dt == null) return '—';
    return DateFormat.yMMMd(loc.toString()).add_Hm().format(dt.toLocal());
  }

  String _fmtMoney(BuildContext context, dynamic raw) {
    if (raw is! num) return raw?.toString() ?? '—';
    final loc = Localizations.localeOf(context);
    final suffix = loc.languageCode == 'ar' ? ' د.ك' : ' KWD';
    final fmt = NumberFormat.decimalPattern(loc.toString());
    return '${fmt.format(raw)}$suffix';
  }

  dynamic _priceRaw(Map<String, dynamic> data) =>
      data['price'] ?? data['expectedPrice'];

  String _listTitle(Map<String, dynamic> data) {
    final title = data['title'];
    if (title != null && title.toString().trim().isNotEmpty) {
      return title.toString();
    }
    final area = (data['area'] ?? data['areaAr'] ?? '').toString();
    final gov = (data['governorate'] ?? data['governorateAr'] ?? '').toString();
    if (area.isNotEmpty && gov.isNotEmpty) return '$area — $gov';
    if (area.isNotEmpty) return area;
    final pt = data['propertyType'];
    return (pt != null && pt.toString().isNotEmpty) ? pt.toString() : '—';
  }

  String _listSubtitle(Map<String, dynamic> data) {
    final legacy = data['location'];
    if (legacy != null && legacy.toString().trim().isNotEmpty) {
      return legacy.toString();
    }
    final pt = data['propertyType'];
    if (pt != null) {
      final gc = data['governorateCode'] ?? '';
      final ac = data['areaCode'] ?? '';
      return '${pt.toString()} · $gc / $ac'.trim();
    }
    return '';
  }

  String _statusLabel(AppLocalizations loc, AuctionRequestStatus s) {
    switch (s) {
      case AuctionRequestStatus.pending:
        return loc.adminAuctionRequestStatusPending;
      case AuctionRequestStatus.approved:
        return loc.adminAuctionRequestStatusApproved;
      case AuctionRequestStatus.rejected:
        return loc.adminAuctionRequestStatusRejected;
    }
  }

  Color _statusColor(AuctionRequestStatus s, ColorScheme cs) {
    switch (s) {
      case AuctionRequestStatus.pending:
        return cs.tertiary;
      case AuctionRequestStatus.approved:
        return Colors.green.shade700;
      case AuctionRequestStatus.rejected:
        return cs.error;
    }
  }

  Future<void> _setStatus(
    BuildContext context,
    String id,
    AuctionRequestStatus status,
  ) async {
    final loc = AppLocalizations.of(context)!;
    if (status == AuctionRequestStatus.rejected) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(loc.adminAuctionRequestConfirmRejectTitle),
          content: Text(loc.adminAuctionRequestConfirmRejectBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(loc.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(loc.adminAuctionRequestReject),
            ),
          ],
        ),
      );
      if (go != true || !context.mounted) return;
    }
    try {
      await AuctionRequestService.updateStatus(requestId: id, status: status);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminAuctionRequestUpdated)),
      );
      if (context.mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${loc.adminAuctionRequestUpdateError}: $e')),
      );
    }
  }

  void _openDetail(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final data = doc.data();
    final status = AuctionRequestStatus.fromFirestore(
      data['status'] as String?,
    );
    final images = (data['images'] as List?)?.cast<dynamic>() ?? const [];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          minChildSize: 0.45,
          maxChildSize: 0.98,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: [
                Text(
                  loc.adminAuctionRequestDetailTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                _kv(theme, loc.adminAuctionRequestUserId, data['userId'] ?? '—'),
                if ((data['propertyId'] as String?)?.isNotEmpty ?? false)
                  _kv(
                    theme,
                    loc.adminAuctionRequestPropertyId,
                    data['propertyId'],
                  ),
                if (data['title'] != null &&
                    data['title'].toString().trim().isNotEmpty)
                  _kv(theme, loc.auctionRequestFieldTitle, data['title']),
                if (data['location'] != null &&
                    data['location'].toString().trim().isNotEmpty)
                  _kv(
                    theme,
                    loc.auctionRequestFieldLocation,
                    data['location'],
                  ),
                if (data['propertyType'] != null)
                  _kv(theme, loc.propertyType, data['propertyType']),
                if (data['governorate'] != null ||
                    data['governorateAr'] != null ||
                    data['area'] != null ||
                    data['areaAr'] != null)
                  _kv(
                    theme,
                    loc.adminAuctionRequestLocationDisplay,
                    '${data['governorate'] ?? data['governorateAr'] ?? '—'} — '
                        '${data['area'] ?? data['areaAr'] ?? '—'}',
                  ),
                if (data['governorateCode'] != null)
                  _kv(
                    theme,
                    loc.adminAuctionRequestGovernorateCode,
                    data['governorateCode'],
                  ),
                if (data['areaCode'] != null)
                  _kv(
                    theme,
                    loc.adminAuctionRequestAreaCode,
                    data['areaCode'],
                  ),
                if (data['size'] != null)
                  _kv(theme, loc.propertySize, '${data['size']}'),
                _kv(
                  theme,
                  loc.adminAuctionRequestExpectedPrice,
                  _fmtMoney(context, _priceRaw(data)),
                ),
                if (data['roomCount'] != null)
                  _kv(theme, loc.roomCount, '${data['roomCount']}'),
                if (data['masterRoomCount'] != null)
                  _kv(theme, loc.masterRoomCount, '${data['masterRoomCount']}'),
                if (data['bathroomCount'] != null)
                  _kv(theme, loc.bathroomCount, '${data['bathroomCount']}'),
                if (data['parkingCount'] != null)
                  _kv(theme, loc.parkingCount, '${data['parkingCount']}'),
                if (data.containsKey('hasElevator'))
                  _kv(
                    theme,
                    loc.hasElevator,
                    data['hasElevator'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                if (data.containsKey('hasCentralAC'))
                  _kv(
                    theme,
                    loc.hasCentralAC,
                    data['hasCentralAC'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                if (data.containsKey('hasSplitAC'))
                  _kv(
                    theme,
                    loc.hasSplitAC,
                    data['hasSplitAC'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                if (data.containsKey('hasMaidRoom'))
                  _kv(
                    theme,
                    loc.hasMaidRoom,
                    data['hasMaidRoom'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                if (data.containsKey('hasDriverRoom'))
                  _kv(
                    theme,
                    loc.hasDriverRoom,
                    data['hasDriverRoom'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                if (data.containsKey('hasLaundryRoom'))
                  _kv(
                    theme,
                    loc.hasLaundryRoom,
                    data['hasLaundryRoom'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                if (data.containsKey('hasGarden'))
                  _kv(
                    theme,
                    loc.hasGarden,
                    data['hasGarden'] == true
                        ? loc.adminAuctionRequestYes
                        : loc.adminAuctionRequestNo,
                  ),
                _kv(
                  theme,
                  loc.adminAuctionRequestAcceptLower,
                  (data['acceptLowerStartPrice'] == true)
                      ? loc.adminAuctionRequestYes
                      : loc.adminAuctionRequestNo,
                ),
                _kv(
                  theme,
                  loc.description,
                  data['description'] ?? '—',
                ),
                const SizedBox(height: 12),
                Text(
                  loc.adminAuctionRequestImages,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                if (images.isEmpty)
                  Text(
                    '—',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  SizedBox(
                    height: 100,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: images.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final url = images[i].toString();
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 100,
                            height: 100,
                            child: CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                              errorWidget: (_, _, _) => ColoredBox(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (status == AuctionRequestStatus.approved) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.35,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        loc.adminAuctionRequestLotReminder,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                    ),
                  ),
                ],
                if (status == AuctionRequestStatus.pending) ...[
                  const SizedBox(height: 20),
                  Text(
                    loc.adminAuctionRequestLotReminder,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () => _setStatus(
                            context,
                            doc.id,
                            AuctionRequestStatus.approved,
                          ),
                          child: Text(loc.adminAuctionRequestApprove),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _setStatus(
                            context,
                            doc.id,
                            AuctionRequestStatus.rejected,
                          ),
                          child: Text(loc.adminAuctionRequestReject),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _kv(ThemeData theme, String k, Object? v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            k,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            v?.toString() ?? '—',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return FutureBuilder<bool>(
      future: _adminGateFuture,
      builder: (context, gate) {
        if (gate.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminAuctionRequestsTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (gate.data != true) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminAuctionRequestsTitle)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline, size: 48, color: Colors.grey.shade600),
                    const SizedBox(height: 16),
                    Text(
                      isAr ? 'يتطلب صلاحية مسؤول' : 'Admin access required',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _retryGate, child: Text(loc.retry)),
                  ],
                ),
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(loc.adminAuctionRequestsTitle),
            centerTitle: true,
          ),
          body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: AuctionRequestService.watchAllRequests(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snap.error.toString(),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Center(
                  child: Text(
                    loc.adminAuctionRequestsEmpty,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final doc = docs[i];
                  final data = doc.data();
                  final status = AuctionRequestStatus.fromFirestore(
                    data['status'] as String?,
                  );
                  final created = data['createdAt'] as Timestamp?;
                  final thumb = (data['images'] as List?)?.cast<dynamic>();
                  final thumbUrl = thumb != null && thumb.isNotEmpty
                      ? thumb.first.toString()
                      : null;

                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _openDetail(context, doc),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 56,
                                height: 56,
                                child: thumbUrl != null
                                    ? CachedNetworkImage(
                                        imageUrl: thumbUrl,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, _, _) =>
                                            ColoredBox(
                                          color: theme.colorScheme
                                              .surfaceContainerHighest,
                                          child: Icon(
                                            Icons.gavel_outlined,
                                            color: theme.colorScheme.outline,
                                          ),
                                        ),
                                      )
                                    : ColoredBox(
                                        color: theme.colorScheme
                                            .surfaceContainerHighest,
                                        child: Icon(
                                          Icons.gavel_outlined,
                                          color: theme.colorScheme.outline,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _listTitle(data),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _listSubtitle(data).isEmpty
                                        ? _fmtMoney(context, _priceRaw(data))
                                        : _listSubtitle(data),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _fmtDate(context, created),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Chip(
                              label: Text(
                                _statusLabel(loc, status),
                                style: const TextStyle(fontSize: 12),
                              ),
                              backgroundColor: _statusColor(
                                status,
                                theme.colorScheme,
                              ).withValues(alpha: 0.15),
                              side: BorderSide.none,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}
