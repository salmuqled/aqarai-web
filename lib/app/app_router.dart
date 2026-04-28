import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:aqarai_app/app/navigation_keys.dart';
import 'package:aqarai_app/app/property_route.dart';
import 'package:aqarai_app/app/safe_app_path.dart';
import 'package:aqarai_app/auth/login_page.dart';
import 'package:aqarai_app/pages/assistant_page.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/widgets/banned_user_session_gate.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';

/// Listens to auth changes so redirect re-evaluates after sign-in / sign-out.
final class GoRouterAuthRefresh extends ChangeNotifier {
  GoRouterAuthRefresh() {
    _sub =
        FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }

  late final StreamSubscription<User?> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final GoRouterAuthRefresh _authRefresh = GoRouterAuthRefresh();

Widget _buildPropertyDetails(GoRouterState state) {
  final propertyId = state.pathParameters['propertyId'] ?? '';
  final q = state.uri.queryParameters;
  final lead = DealLeadSource.normalizeAttributionSource(q['lead']);
  final cid = q['cid']?.trim();
  final auctionLot = q['auctionLot']?.trim();
  final auction = q['auction']?.trim();
  final isAdmin = q['admin'] == '1';
  DateTime? stayStart;
  DateTime? stayEnd;
  final ss = q['stayStart']?.trim();
  final se = q['stayEnd']?.trim();
  if (ss != null && ss.isNotEmpty) stayStart = DateTime.tryParse(ss);
  if (se != null && se.isNotEmpty) stayEnd = DateTime.tryParse(se);
  final rental = q['rental']?.trim();

  return BannedUserSessionGate(
    child: PropertyDetailsPage(
      propertyId: propertyId,
      isAdminView: isAdmin,
      leadSource: lead,
      captionTrackingId:
          (cid != null && cid.isNotEmpty) ? cid : null,
      auctionLotId: (auctionLot != null && auctionLot.isNotEmpty)
          ? auctionLot
          : null,
      auctionId: (auction != null && auction.isNotEmpty) ? auction : null,
      stayStart: stayStart,
      stayEnd: stayEnd,
      rentalType: (rental != null && rental.isNotEmpty) ? rental : null,
    ),
  );
}

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  refreshListenable: _authRefresh,
  initialLocation: '/',
  redirect: (context, state) {
    final user = FirebaseAuth.instance.currentUser;
    final path = state.uri.path;
    final loggingIn = path == '/login';

    if (user == null) {
      if (loggingIn) return null;
      final full =
          '${state.uri.path}${state.uri.hasQuery ? '?${state.uri.query}' : ''}';
      return '/login?redirect=${Uri.encodeComponent(full)}';
    }

    if (loggingIn) {
      final raw = state.uri.queryParameters['redirect'];
      return safeAppPath(raw) ?? '/';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/login',
      builder: (context, state) {
        final raw = state.uri.queryParameters['redirect'];
        return LoginPage(returnTo: safeAppPath(raw));
      },
    ),
    GoRoute(
      path: '/',
      builder: (context, state) => const BannedUserSessionGate(
        child: AssistantPage(),
      ),
    ),
    GoRoute(
      path: PropertyRoute.pathPattern,
      builder: (context, state) => _buildPropertyDetails(state),
    ),
  ],
);
