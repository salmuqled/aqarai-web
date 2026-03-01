import 'dart:convert';
import 'dart:io';

Set<String> _keys(Map<String, dynamic> m) {
  return m.keys
      .where((k) => !k.startsWith('@') && k != '@@locale')
      .toSet();
}

Future<void> main() async {
  final arFile = File('lib/l10n/app_ar.arb');
  final enFile = File('lib/l10n/app_en.arb');

  if (!await arFile.exists()) {
    stderr.writeln('❌ Missing file: ${arFile.path}');
    exit(1);
  }
  if (!await enFile.exists()) {
    stderr.writeln('❌ Missing file: ${enFile.path}');
    exit(1);
  }

  final ar = jsonDecode(await arFile.readAsString()) as Map<String, dynamic>;
  final en = jsonDecode(await enFile.readAsString()) as Map<String, dynamic>;

  final arKeys = _keys(ar);
  final enKeys = _keys(en);

  final missingInAr = enKeys.difference(arKeys).toList()..sort();
  final missingInEn = arKeys.difference(enKeys).toList()..sort();

  if (missingInAr.isEmpty && missingInEn.isEmpty) {
    stdout.writeln('✅ L10N OK: app_ar.arb and app_en.arb keys match.');
    return;
  }

  stdout.writeln('❌ L10N MISMATCH:');

  if (missingInAr.isNotEmpty) {
    stdout.writeln('\nMissing in app_ar.arb (${missingInAr.length}):');
    for (final k in missingInAr) {
      stdout.writeln(' - $k');
    }
  }

  if (missingInEn.isNotEmpty) {
    stdout.writeln('\nMissing in app_en.arb (${missingInEn.length}):');
    for (final k in missingInEn) {
      stdout.writeln(' - $k');
    }
  }

  exitCode = 1;
}
