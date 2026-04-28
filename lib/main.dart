import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'package:aqarai_app/firebase_options.dart';
import 'package:aqarai_app/app/app_router.dart';
import 'package:aqarai_app/app/auth_bootstrap.dart';
import 'package:aqarai_app/services/admin_client_error_reporter.dart';
import 'package:aqarai_app/services/deal_follow_up_local_notifications.dart';
import 'package:aqarai_app/services/notification_service.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// ⭐ نظام تغيير اللغة الموجود عندك
import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/app/locale_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();

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
        return MaterialApp.router(
          routerConfig: appRouter,
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
              child: AuthBootstrap(child: child ?? const SizedBox.shrink()),
            );
          },
        );
      },
    );
  }
}
