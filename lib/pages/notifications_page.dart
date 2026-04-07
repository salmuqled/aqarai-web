import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/notification_service.dart';
import 'package:aqarai_app/services/user_notifications_inbox_service.dart';

enum _DateBucket { today, yesterday, older }

/// In-app notification center (Firestore `notifications`, limit 50, live stream).
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  static const Color _primary = Color(0xFF101046);
  static const Duration _undoSnackBarDuration = Duration(seconds: 4);

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _firstUnreadKey = GlobalKey();
  bool _didScrollToFirstUnread = false;
  bool _scrollToUnreadScheduled = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  static String _timeAgo(Timestamp? ts, bool isAr) {
    if (ts == null) return '';
    final diff = DateTime.now().difference(ts.toDate());
    if (diff.inSeconds < 45) {
      return isAr ? 'الآن' : 'Just now';
    }
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return isAr ? 'منذ $m د' : '${m}m ago';
    }
    if (diff.inHours < 48) {
      final h = diff.inHours;
      return isAr ? 'منذ $h س' : '${h}h ago';
    }
    final d = diff.inDays;
    return isAr ? 'منذ $d يوم' : '${d}d ago';
  }

  static String _typeEmoji(String? rawType) {
    switch ((rawType ?? '').toLowerCase().trim()) {
      case 'booking':
        return '📩';
      case 'payout':
        return '💰';
      case 'refund':
        return '↩️';
      case 'cancel':
        return '❌';
      default:
        return '🔔';
    }
  }

  static _DateBucket _bucketFor(Timestamp? ts) {
    if (ts == null) return _DateBucket.older;
    final docDay = DateUtils.dateOnly(ts.toDate());
    final today = DateUtils.dateOnly(DateTime.now());
    if (docDay == today) return _DateBucket.today;
    if (docDay == today.subtract(const Duration(days: 1))) {
      return _DateBucket.yesterday;
    }
    return _DateBucket.older;
  }

  static String _bucketLabel(_DateBucket b, AppLocalizations loc) {
    switch (b) {
      case _DateBucket.today:
        return loc.notificationsGroupToday;
      case _DateBucket.yesterday:
        return loc.notificationsGroupYesterday;
      case _DateBucket.older:
        return loc.notificationsGroupOlder;
    }
  }

  /// Unread block first; read items follow with Today/Yesterday/Older (and a «Read»
  /// header when both blocks exist).
  static List<_InboxListItem> _buildInboxItems(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    AppLocalizations loc,
  ) {
    if (docs.isEmpty) return const [];

    final unread = docs
        .where((d) => d.data()['isRead'] != true)
        .toList(growable: false);
    final read =
        docs.where((d) => d.data()['isRead'] == true).toList(growable: false);

    final out = <_InboxListItem>[];
    if (unread.isNotEmpty) {
      out.add(
        _InboxListItem.header(loc.notificationsSectionUnreadCount(unread.length)),
      );
      for (final d in unread) {
        out.add(_InboxListItem.row(d));
      }
    }
    if (read.isNotEmpty) {
      if (unread.isNotEmpty) {
        out.add(_InboxListItem.header(loc.notificationsSectionRead));
      }
      _DateBucket? lastBucket;
      for (final doc in read) {
        final created = doc.data()['createdAt'];
        final ts = created is Timestamp ? created : null;
        final bucket = _bucketFor(ts);
        if (bucket != lastBucket) {
          out.add(_InboxListItem.header(_bucketLabel(bucket, loc)));
          lastBucket = bucket;
        }
        out.add(_InboxListItem.row(doc));
      }
    }
    return out;
  }

  static int? _firstUnreadIndex(List<_InboxListItem> items) {
    for (var i = 0; i < items.length; i++) {
      final e = items[i];
      if (!e.isHeader &&
          e.doc != null &&
          e.doc!.data()['isRead'] != true) {
        return i;
      }
    }
    return null;
  }

  void _scheduleScrollToFirstUnread(List<_InboxListItem> items) {
    if (_didScrollToFirstUnread) return;
    if (_firstUnreadIndex(items) == null) {
      _didScrollToFirstUnread = true;
      return;
    }
    if (_scrollToUnreadScheduled) return;
    _scrollToUnreadScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToUnreadScheduled = false;
      if (!mounted || _didScrollToFirstUnread) return;
      var ctx = _firstUnreadKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.08,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
        _didScrollToFirstUnread = true;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _didScrollToFirstUnread) return;
        final ctx2 = _firstUnreadKey.currentContext;
        if (ctx2 != null) {
          Scrollable.ensureVisible(
            ctx2,
            alignment: 0.08,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
          );
        }
        _didScrollToFirstUnread = true;
      });
    });
  }

  static Future<void> _markAsReadIfNeeded(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    if (doc.data()['isRead'] == true) return;
    try {
      await FirebaseFirestore.instance
          .collection('notifications')
          .doc(doc.id)
          .update({'isRead': true});
    } catch (e) {
      debugPrint('notification mark read: $e');
    }
  }

  static Future<void> _persistHide(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    await FirebaseFirestore.instance
        .collection('notifications')
        .doc(doc.id)
        .update({'isHidden': true});
  }

  static Future<void> _undoHide(String docId) async {
    try {
      await FirebaseFirestore.instance
          .collection('notifications')
          .doc(docId)
          .update({'isHidden': false});
    } catch (e) {
      debugPrint('undo hide: $e');
    }
  }

  static Future<void> _onNotificationTap(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = UserNotificationsInboxService.deepLinkDataFromDoc(doc);
    await _markAsReadIfNeeded(doc);
    if (!context.mounted) return;
    NotificationService.navigateCommerceDeepLink(data);
  }

  void _showNotificationLongPressMenu(
    BuildContext context,
    AppLocalizations loc,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    bool read,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!read)
                ListTile(
                  leading: Icon(Icons.mark_email_read_rounded, color: _primary),
                  title: Text(loc.notificationsSwipeMarkRead),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_markAsReadIfNeeded(doc));
                  },
                ),
              ListTile(
                leading: Icon(Icons.visibility_off_rounded,
                    color: Colors.red.shade700),
                title: Text(loc.notificationsSwipeDismiss),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final hid = doc.id;
                  try {
                    await _persistHide(doc);
                  } catch (e) {
                    debugPrint('notification hide: $e');
                    return;
                  }
                  if (context.mounted) {
                    _showHideUndoSnackBar(context, loc, hid);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showHideUndoSnackBar(
    BuildContext context,
    AppLocalizations loc,
    String docId,
  ) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.notificationsHiddenSnackbar),
        duration: _undoSnackBarDuration,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: loc.notificationsUndoHide,
          onPressed: () {
            unawaited(_undoHide(docId));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null || uid.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(loc.notificationsInboxTitle)),
        body: Center(child: Text(loc.notificationsInboxEmpty)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        title: Text(loc.notificationsInboxTitle),
        actions: [
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: UserNotificationsInboxService.inboxStream(uid),
            builder: (context, snap) {
              if (!snap.hasData) return const SizedBox.shrink();
              final data = snap.data!;
              final docs = data.docs;
              if (docs.isEmpty) return const SizedBox.shrink();

              final unread =
                  docs.where((d) => d.data()['isRead'] != true).length;

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () async {
                      try {
                        await UserNotificationsInboxService.hideAllVisibleFromSnapshot(
                          data,
                        );
                      } catch (e) {
                        debugPrint('hide all: $e');
                      }
                    },
                    child: Text(
                      loc.notificationsHideAll,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (unread > 0)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () async {
                        try {
                          await UserNotificationsInboxService.markAllReadFromSnapshot(
                            data,
                          );
                        } catch (e) {
                          debugPrint('mark all read: $e');
                        }
                      },
                      child: Text(
                        loc.notificationsMarkAllRead,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: UserNotificationsInboxService.inboxStream(uid),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];

          if (docs.isEmpty) {
            return RefreshIndicator(
              color: _primary,
              onRefresh: () async {
                await UserNotificationsInboxService.inboxQuery(uid).get();
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.35,
                    child: Center(
                      child: Text(
                        loc.notificationsInboxEmpty,
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 16, color: Colors.grey.shade700),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          final items = _buildInboxItems(docs, loc);
          final firstUnreadIdx = _firstUnreadIndex(items);
          _scheduleScrollToFirstUnread(items);

          return RefreshIndicator(
            color: _primary,
            onRefresh: () async {
              await UserNotificationsInboxService.inboxQuery(uid).get();
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = items[index];
                        if (item.isHeader) {
                          return Padding(
                            padding: EdgeInsets.only(
                              bottom: 8,
                              top: index == 0 ? 0 : 16,
                            ),
                            child: Text(
                              item.sectionTitle!,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                                color: Colors.grey.shade800,
                              ),
                            ),
                          );
                        }

                        final doc = item.doc!;
                        final m = doc.data();
                        final title = m['title']?.toString() ?? '';
                        final body = m['body']?.toString() ?? '';
                        final read = m['isRead'] == true;
                        final created =
                            m['createdAt'] is Timestamp ? m['createdAt'] as Timestamp : null;
                        final nType = m['notificationType']?.toString();
                        final emoji = _typeEmoji(nType);
                        final highPriority = UserNotificationsInboxService.isHighPriority(m);
                        final firstUnreadFocus =
                            firstUnreadIdx != null && index == firstUnreadIdx && !read;

                        final card = _NotificationCard(
                          primary: _primary,
                          title: title,
                          body: body,
                          read: read,
                          highPriority: highPriority,
                          firstUnreadFocus: firstUnreadFocus,
                          timeLabel: _timeAgo(created, isAr),
                          emoji: emoji,
                          onTap: () => _onNotificationTap(context, doc),
                        );

                        Widget tile = Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: GestureDetector(
                            onLongPress: () => _showNotificationLongPressMenu(
                              context,
                              loc,
                              doc,
                              read,
                            ),
                            behavior: HitTestBehavior.opaque,
                            child: Dismissible(
                              key: Key('inbox_${doc.id}'),
                              direction: DismissDirection.horizontal,
                              background: _SwipeBackground(
                                alignment: Alignment.centerLeft,
                                color: Colors.green.shade700,
                                icon: Icons.mark_email_read_rounded,
                                label: loc.notificationsSwipeMarkRead,
                              ),
                              secondaryBackground: _SwipeBackground(
                                alignment: Alignment.centerRight,
                                color: Colors.red.shade700,
                                icon: Icons.visibility_off_rounded,
                                label: loc.notificationsSwipeDismiss,
                              ),
                              confirmDismiss: (direction) async {
                                if (direction == DismissDirection.startToEnd) {
                                  await _markAsReadIfNeeded(doc);
                                  return false;
                                }
                                if (direction == DismissDirection.endToStart) {
                                  final hid = doc.id;
                                  try {
                                    await _persistHide(doc);
                                  } catch (e) {
                                    debugPrint('notification hide: $e');
                                    return false;
                                  }
                                  if (context.mounted) {
                                    _showHideUndoSnackBar(context, loc, hid);
                                  }
                                  return false;
                                }
                                return false;
                              },
                              child: card,
                            ),
                          ),
                        );

                        if (firstUnreadIdx != null && index == firstUnreadIdx) {
                          tile = KeyedSubtree(
                            key: _firstUnreadKey,
                            child: tile,
                          );
                        }

                        return tile;
                      },
                      childCount: items.length,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _InboxListItem {
  _InboxListItem.header(this.sectionTitle) : doc = null;
  _InboxListItem.row(this.doc) : sectionTitle = null;

  final String? sectionTitle;
  final QueryDocumentSnapshot<Map<String, dynamic>>? doc;

  bool get isHeader => sectionTitle != null;
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Align(
          alignment: alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (alignment == Alignment.centerRight) ...[
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(icon, color: Colors.white, size: 26),
              if (alignment == Alignment.centerLeft) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.primary,
    required this.title,
    required this.body,
    required this.read,
    required this.highPriority,
    this.firstUnreadFocus = false,
    required this.timeLabel,
    required this.emoji,
    required this.onTap,
  });

  final Color primary;
  final String title;
  final String body;
  final bool read;
  final bool highPriority;
  final bool firstUnreadFocus;
  final String timeLabel;
  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unreadBase = Color.alphaBlend(
      primary.withValues(alpha: 0.08),
      const Color(0xFFEEF2FB),
    );
    final unreadBg = highPriority
        ? Color.alphaBlend(
            const Color(0x1A1565C0),
            unreadBase,
          )
        : unreadBase;

    final readBg = highPriority
        ? Color.alphaBlend(
            primary.withValues(alpha: 0.06),
            Colors.white,
          )
        : Colors.white;

    final borderColor = highPriority
        ? primary.withValues(alpha: read ? 0.45 : 0.55)
        : (read ? Colors.black.withValues(alpha: 0.06) : primary.withValues(alpha: 0.28));
    var borderWidth =
        highPriority ? (read ? 2.0 : 2.25) : (read ? 1.0 : 1.25);
    var effectiveBorderColor = borderColor;
    if (firstUnreadFocus) {
      borderWidth += 0.95;
      effectiveBorderColor = Color.alphaBlend(
        primary.withValues(alpha: 0.42),
        borderColor,
      );
    }

    final shadow = <BoxShadow>[
      if (!read || highPriority)
        BoxShadow(
          color: primary.withValues(alpha: read ? 0.08 : 0.22),
          blurRadius: highPriority ? 10 : 8,
          offset: const Offset(0, 3),
        ),
      if (firstUnreadFocus)
        BoxShadow(
          color: primary.withValues(alpha: 0.38),
          blurRadius: 16,
          spreadRadius: 0.5,
          offset: const Offset(0, 4),
        ),
    ];

    final surface = AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: read ? readBg : unreadBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: effectiveBorderColor, width: borderWidth),
        boxShadow: shadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!read)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    width: 4,
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: const BorderRadiusDirectional.horizontal(
                        start: Radius.circular(14),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.35),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding:
                              const EdgeInsetsDirectional.only(top: 2, end: 2),
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 22, height: 1),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (!read)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              top: 6,
                              end: 6,
                            ),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: primary,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: primary.withValues(alpha: 0.45),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontWeight: read
                                      ? FontWeight.w600
                                      : FontWeight.w800,
                                  fontSize: 15,
                                  color: Colors.grey.shade900,
                                  height: 1.2,
                                ),
                              ),
                              if (body.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  body,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.35,
                                    color: read
                                        ? Colors.grey.shade700
                                        : Colors.grey.shade900,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Text(
                                timeLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                  fontWeight:
                                      read ? FontWeight.w400 : FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!firstUnreadFocus) return surface;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 820),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        final scale = 1 + 0.022 * math.sin(t * math.pi);
        return Transform.scale(scale: scale, child: child);
      },
      child: surface,
    );
  }
}
