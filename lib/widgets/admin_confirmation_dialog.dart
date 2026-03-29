import 'package:flutter/material.dart';

/// حوار تأكيد قبل تنفيذ إجراء أدمن خطير (لا تنفيذ تلقائي).
Future<void> showAdminConfirmationDialog({
  required BuildContext context,
  required String title,
  required String description,
  required Future<void> Function() onConfirm,
  required bool isAr,
}) async {
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(description)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await onConfirm();
            },
            child: Text(isAr ? 'تأكيد' : 'Confirm'),
          ),
        ],
      );
    },
  );
}
