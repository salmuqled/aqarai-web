import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

/// Shows confirmation copy + required phone, returns trimmed phone or `null` if cancelled / not signed in.
Future<String?> showInterestedLeadPhoneSheet(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  final isAr = Localizations.localeOf(context).languageCode == 'ar';

  if (user == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          isAr ? 'يرجى تسجيل الدخول لمتابعة الطلب' : 'Please sign in to continue',
        ),
      ),
    );
    return null;
  }

  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) {
      return _InterestedLeadPhoneSheetBody(userId: user.uid);
    },
  );

  return result == null || result.isEmpty ? null : result;
}

class _InterestedLeadPhoneSheetBody extends StatefulWidget {
  const _InterestedLeadPhoneSheetBody({required this.userId});

  final String userId;

  @override
  State<_InterestedLeadPhoneSheetBody> createState() =>
      _InterestedLeadPhoneSheetBodyState();
}

class _InterestedLeadPhoneSheetBodyState
    extends State<_InterestedLeadPhoneSheetBody> {
  final _phoneCtrl = TextEditingController();
  final _focus = FocusNode();
  String? _phoneError;
  bool _loadingPrefill = true;

  @override
  void initState() {
    super.initState();
    _loadPrefill();
  }

  Future<void> _loadPrefill() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .get();
      final p = doc.data()?['phone']?.toString().trim();
      if (p != null && p.isNotEmpty && mounted) {
        _phoneCtrl.text = p;
      }
    } catch (_) {
      // ignore prefill errors
    } finally {
      if (mounted) setState(() => _loadingPrefill = false);
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(BuildContext ctx) {
    final loc = AppLocalizations.of(ctx)!;
    final t = _phoneCtrl.text.trim();
    if (t.isEmpty) {
      setState(() {
        _phoneError = loc.interestedLeadPhoneRequired;
      });
      return;
    }
    setState(() => _phoneError = null);
    Navigator.of(ctx).pop(t);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final inset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: inset),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                loc.interestedLeadConfirmationBody,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.45) ??
                    const TextStyle(fontSize: 16, height: 1.45),
                textAlign: TextAlign.start,
              ),
              const SizedBox(height: 20),
              if (_loadingPrefill)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                TextField(
                  controller: _phoneCtrl,
                  focusNode: _focus,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: InputDecoration(
                    labelText: loc.interestedLeadPhoneLabel,
                    errorText: _phoneError,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_phoneError != null) {
                      setState(() => _phoneError = null);
                    }
                  },
                  onSubmitted: (_) => _submit(context),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loadingPrefill ? null : () => _submit(context),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(loc.interestedLeadConfirmationContinue),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(loc.cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
