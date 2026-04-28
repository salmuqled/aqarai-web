import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/deal_follow_up_local_notifications.dart';

/// Side effects that used to live in [AuthGate]: token refresh + local notification flush.
class AuthBootstrap extends StatefulWidget {
  const AuthBootstrap({super.key, required this.child});

  final Widget child;

  @override
  State<AuthBootstrap> createState() => _AuthBootstrapState();
}

class _AuthBootstrapState extends State<AuthBootstrap> {
  StreamSubscription<User?>? _authSub;
  String? _followUpLaunchFlushUid;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        unawaited(AuthService.refreshIdTokenClaims());
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          _followUpLaunchFlushUid = null;
          return widget.child;
        }

        final uid = snapshot.data!.uid;
        if (_followUpLaunchFlushUid != uid) {
          _followUpLaunchFlushUid = uid;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            DealFollowUpLocalNotifications.flushPendingLaunchNavigation();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              DealFollowUpLocalNotifications.flushPendingLaunchNavigation();
            });
          });
        }

        return widget.child;
      },
    );
  }
}
