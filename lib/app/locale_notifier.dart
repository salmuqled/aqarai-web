import 'package:flutter/material.dart';

final ValueNotifier<Locale> appLocale = ValueNotifier<Locale>(
  const Locale('ar'),
);

void setAppLocale(Locale locale) {
  appLocale.value = locale;
}

void toggleAppLocale() {
  final current = appLocale.value.languageCode;
  appLocale.value = Locale(current == 'ar' ? 'en' : 'ar');
}
