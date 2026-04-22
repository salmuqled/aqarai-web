import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:aqarai_app/firebase_options.dart';
import 'package:aqarai_app/auth/login_page.dart';
import 'package:aqarai_app/pages/assistant_page.dart';
import 'package:aqarai_app/app/navigation_keys.dart';
import 'package:aqarai_app/services/admin_client_error_reporter.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/deal_follow_up_local_notifications.dart';
import 'package:aqarai_app/services/notification_service.dart';
import 'package:aqarai_app/widgets/banned_user_session_gate.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// ⭐ نظام تغيير اللغة الموجود عندك
import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/app/locale_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (Firebase.apps.isEmpty) {
      throw StateError('Firebase.initializeApp completed but Firebase.apps is empty');
    }
    if (kDebugMode) {
      final o = Firebase.app().options;
      debugPrint(
        '[Firebase] Initialized OK | projectId=${o.projectId} '
        'appId=${o.appId}',
      );
    }
  } catch (e, st) {
    debugPrint('[Firebase] initializeApp FAILED: $e');
    debugPrint('$st');
    rethrow;
  }

  FirebaseMessaging.onBackgroundMessage(
    NotificationService.firebaseMessagingBackgroundHandler,
  );

  await DealFollowUpLocalNotifications.initialize();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    AdminClientErrorReporter.scheduleReport(
      details.exception,
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AdminClientErrorReporter.scheduleReport(error, stack);
    return true;
  };

  runZonedGuarded(
    () => runApp(const MyApp()),
    (Object error, StackTrace stack) {
      AdminClientErrorReporter.scheduleReport(error, stack);
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ⭐ نربط MaterialApp مع ValueListenableBuilder
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, _) {
        return MaterialApp(
          navigatorKey: rootNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: aqarAiLightTheme(),

          // ⭐ اللغة الحالية تأتي من appLocale
          locale: locale,

          // ⭐ دعم اللغات
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],

          // ⭐ في حال لم يتم التعرف على اللغة
          localeResolutionCallback: (locale, supportedLocales) {
            return supportedLocales.contains(locale)
                ? locale
                : const Locale('ar');
          },

          // Global "tap-outside-to-dismiss keyboard" at the Navigator root so
          // every screen (including pushed routes and modal bottom sheets)
          // inherits the behavior. `HitTestBehavior.translucent` lets child
          // widgets still receive their own taps first — buttons, links and
          // TextFields keep working normally, and this handler only fires
          // when a tap lands on inert space. Child widgets that call
          // [FocusScope.requestFocus] after this handler runs also work as
          // expected (e.g. another TextField stealing focus mid-tap).
          builder: (context, child) {
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              child: child,
            );
          },

          home: const AuthGate(),
        );
      },
    );
  }
}

/// ----------------------------------------------------------------
/// 🔐 AuthGate
/// ----------------------------------------------------------------
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<User?>? _authSub;
  String? _followUpLaunchFlushUid;

  @override
  void initState() {
    super.initState();
    // يجبر تحديث التوكن عند أي جلسة (بعد تعيين admin على السيرفر لازم يبان في Firestore).
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
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (!snapshot.hasData) {
          _followUpLaunchFlushUid = null;
          return const LoginPage();
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

        return const BannedUserSessionGate(
          child: AssistantPage(),
        );
      },
    );
  }
}
