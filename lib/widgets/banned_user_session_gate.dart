import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/user_ban_service.dart';

/// Signs the user out if `users/{uid}` shows a ban (backup for Auth disable / token lag).
class BannedUserSessionGate extends StatefulWidget {
  const BannedUserSessionGate({super.key, required this.child});

  final Widget child;

  @override
  State<BannedUserSessionGate> createState() => _BannedUserSessionGateState();
}

class _BannedUserSessionGateState extends State<BannedUserSessionGate> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _handled = false;
      return widget.child;
    }

    return StreamBuilder<bool>(
      stream: UserBanService.watchCurrentUserBanned(),
      builder: (context, snap) {
        final banned = snap.data == true;
        if (banned && !_handled) {
          _handled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!context.mounted) return;
            final loc = AppLocalizations.of(context);
            await showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: Text(loc?.accountSuspendedTitle ?? 'Account restricted'),
                content: Text(
                  loc?.accountSuspendedBody ??
                      'This account is no longer allowed to use the app.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(loc?.cancel ?? 'OK'),
                  ),
                ],
              ),
            );
            await FirebaseAuth.instance.signOut();
          });
        }
        return widget.child;
      },
    );
  }
}
