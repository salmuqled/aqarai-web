import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/pages/notifications_page.dart';
import 'package:aqarai_app/services/user_notifications_inbox_service.dart';

/// 🔔 + unread badge; opens [NotificationsPage].
class NotificationsInboxBellButton extends StatelessWidget {
  const NotificationsInboxBellButton({
    super.key,
    required this.isOnDarkBackground,
  });

  /// Home hero uses dark overlay; assistant header uses light capsule.
  final bool isOnDarkBackground;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final uid = authSnap.data?.uid;
        if (uid == null || uid.isEmpty) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<int>(
          stream: UserNotificationsInboxService.unreadCountRecentStream(uid),
          builder: (context, countSnap) {
            final unread = countSnap.data ?? 0;
            final bg = isOnDarkBackground
                ? Colors.black.withValues(alpha: 0.35)
                : const Color(0xFFF1F1F1);
            final iconColor =
                isOnDarkBackground ? Colors.white : const Color(0xFF1A1A1A);

            return Material(
              color: bg,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NotificationsPage(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.notifications_outlined, color: iconColor, size: 22),
                      if (unread > 0)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                            decoration: BoxDecoration(
                              color: Colors.red.shade600,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                height: 1.1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
