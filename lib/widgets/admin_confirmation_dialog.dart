import 'package:flutter/material.dart';

/// حوار تأكيد قبل تنفيذ إجراء أدمن خطير (لا تنفيذ تلقائي).
///
/// يعطّل «تأكيد» فورًا (متزامنًا) ثم يُظهر تحميل حتى ينتهي [onConfirm]،
/// لتفادي طلبين لـ Cloud Functions على iOS (GTMSessionFetcher was already running).
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
    builder: (dialogCtx) {
      var submitting = false;
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final cs = Theme.of(context).colorScheme;

          void runConfirm() {
            if (submitting) return;
            submitting = true;
            setDialogState(() {});
            Future<void> work() async {
              try {
                await onConfirm();
              } finally {
                if (dialogCtx.mounted) {
                  Navigator.of(dialogCtx).pop();
                }
              }
            }

            work();
          }

          return PopScope(
            canPop: !submitting,
            child: AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(child: Text(description)),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.of(dialogCtx).pop(),
                  child: Text(isAr ? 'إلغاء' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: submitting ? null : runConfirm,
                  child: submitting
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: cs.onPrimary,
                          ),
                        )
                      : Text(isAr ? 'تأكيد' : 'Confirm'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
