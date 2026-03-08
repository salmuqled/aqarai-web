import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:aqarai_app/firebase_options.dart';
import 'package:aqarai_app/auth/login_page.dart';
import 'package:aqarai_app/pages/assistant_page.dart';
import 'package:aqarai_app/services/notification_service.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// ⭐ نظام تغيير اللغة الموجود عندك
import 'package:aqarai_app/app/locale_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(
    NotificationService.firebaseMessagingBackgroundHandler,
  );
  runApp(const MyApp());
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
          debugShowCheckedModeBanner: false,

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

          home: const AuthGate(),
        );
      },
    );
  }
}

/// ----------------------------------------------------------------
/// 🔐 AuthGate
/// ----------------------------------------------------------------
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

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
          return const LoginPage();
        }

        return const AssistantPage();
      },
    );
  }
}
