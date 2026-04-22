import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aqarai_app/services/interest_lead_flow_service.dart';

/// Pure, side-effect-free validator for Kuwaiti mobile numbers used at
/// booking-time. The contract is intentionally narrow so the rule can be
/// reused from any caller (UI, tests, services) without surprises.
///
/// Valid shape: exactly 8 ASCII digits whose first digit is one of
/// `9`, `6`, `5`, `4`. This matches the current Kuwaiti mobile prefix
/// space used by the rest of the project.
abstract final class BookingPhoneValidator {
  BookingPhoneValidator._();

  // Hoisted to module scope so the pattern is compiled exactly once.
  static final RegExp _kuwaitiMobile = RegExp(r'^[9654]\d{7}$');

  /// Returns `true` iff [raw], after trimming, is a valid Kuwaiti mobile.
  /// Null / empty / wrong length / non-digit input all return `false`.
  static bool isValidKuwaiti(String? raw) {
    if (raw == null) return false;
    final t = raw.trim();
    if (t.length != 8) return false;
    return _kuwaitiMobile.hasMatch(t);
  }
}

/// Three-way outcome of the "light confirm" sheet shown on repeat bookings.
enum BookingPhoneConfirmChoice {
  /// User confirmed the existing phone and wants to proceed.
  continueBooking,

  /// User asked to edit; caller should re-open the capture sheet.
  edit,
}

/// Shows the first-time phone capture sheet. Blocks until the user either
/// submits a valid Kuwaiti phone (which is persisted to `users/{uid}.phone`
/// via [InterestLeadFlowService.saveUserPhone]) or dismisses the sheet.
///
/// Returns the trimmed saved phone on success, or `null` if the user
/// cancelled / is not signed in / save failed.
Future<String?> showBookingPhoneCaptureSheet(
  BuildContext context, {
  String initial = '',
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    isDismissible: true,
    enableDrag: true,
    builder: (ctx) => _BookingPhoneCaptureBody(
      uid: user.uid,
      initialPhone: initial,
    ),
  );
}

/// Shows the lightweight confirm sheet when the user already has a saved
/// phone. Resolves to [BookingPhoneConfirmChoice.continueBooking] or
/// [BookingPhoneConfirmChoice.edit]; `null` means the user dismissed.
Future<BookingPhoneConfirmChoice?> showBookingPhoneConfirmSheet(
  BuildContext context, {
  required String existingPhone,
}) {
  return showModalBottomSheet<BookingPhoneConfirmChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    isDismissible: true,
    enableDrag: true,
    builder: (ctx) => _BookingPhoneConfirmBody(existingPhone: existingPhone),
  );
}

class _BookingPhoneCaptureBody extends StatefulWidget {
  const _BookingPhoneCaptureBody({
    required this.uid,
    required this.initialPhone,
  });

  final String uid;
  final String initialPhone;

  @override
  State<_BookingPhoneCaptureBody> createState() =>
      _BookingPhoneCaptureBodyState();
}

class _BookingPhoneCaptureBodyState extends State<_BookingPhoneCaptureBody> {
  late final TextEditingController _phoneCtrl;
  final FocusNode _focus = FocusNode();
  String? _errorText;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _phoneCtrl = TextEditingController(text: widget.initialPhone.trim());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit(bool isAr) async {
    if (_saving) return;
    final candidate = _phoneCtrl.text.trim();
    if (!BookingPhoneValidator.isValidKuwaiti(candidate)) {
      setState(() {
        _errorText = isAr
            ? 'يرجى إدخال رقم كويتي صحيح'
            : 'Please enter a valid Kuwaiti number';
      });
      return;
    }
    setState(() {
      _errorText = null;
      _saving = true;
    });
    try {
      await InterestLeadFlowService.saveUserPhone(
        uid: widget.uid,
        phone: candidate,
      );
      if (!mounted) return;
      Navigator.of(context).pop(candidate);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = isAr
            ? 'تعذر حفظ الرقم، حاول مرة أخرى'
            : 'Could not save phone. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final inset = MediaQuery.viewInsetsOf(context).bottom;

    // Shared soft-fill / thin-border tokens so the country-code chip and the
    // input visually belong to the same family.
    final Color fieldFill = cs.surfaceContainerHighest.withValues(alpha: 0.45);
    final Color fieldBorder = cs.outline.withValues(alpha: 0.22);
    final Color focusBorder = cs.primary.withValues(alpha: 0.55);
    const double fieldRadius = 12;
    const double fieldHeight = 52;

    final OutlineInputBorder baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(fieldRadius),
      borderSide: BorderSide(color: fieldBorder),
    );
    final OutlineInputBorder focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(fieldRadius),
      borderSide: BorderSide(color: focusBorder, width: 1.4),
    );

    final bool hasError = _errorText != null;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: inset),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(22, 4, 22, 20 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title — strong hierarchy, respects ambient RTL.
              Text(
                isAr
                    ? 'أدخل رقم هاتفك لإتمام الحجز'
                    : 'Enter your phone to complete the booking',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.3,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 6),
              // Subtitle — smaller + lighter, single short line.
              Text(
                isAr
                    ? 'نحفظ رقمك لاستخدامه في الحجوزات القادمة'
                    : 'We save it for your future bookings',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.58),
                  height: 1.35,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 22),

              // Phone row: fixed "+965" chip on the LEFT, input on the RIGHT.
              // Forced LTR so the country code always sits to the visual left
              // regardless of the surrounding Arabic layout.
              Directionality(
                textDirection: TextDirection.ltr,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      height: fieldHeight,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: fieldFill,
                        borderRadius: BorderRadius.circular(fieldRadius),
                        border: Border.all(color: fieldBorder),
                      ),
                      child: Text(
                        '+965',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface.withValues(alpha: 0.82),
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: fieldHeight,
                        child: TextField(
                          controller: _phoneCtrl,
                          focusNode: _focus,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.telephoneNumber],
                          enabled: !_saving,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.left,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(8),
                          ],
                          decoration: InputDecoration(
                            isDense: true,
                            hintText:
                                isAr ? 'أدخل رقم الهاتف' : 'Enter phone number',
                            hintStyle: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.38),
                              fontWeight: FontWeight.w500,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 14,
                            ),
                            filled: true,
                            fillColor: fieldFill,
                            border: baseBorder,
                            enabledBorder: hasError
                                ? OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(fieldRadius),
                                    borderSide: BorderSide(
                                      color: cs.error
                                          .withValues(alpha: 0.55),
                                    ),
                                  )
                                : baseBorder,
                            focusedBorder: hasError
                                ? OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(fieldRadius),
                                    borderSide: BorderSide(
                                      color: cs.error,
                                      width: 1.4,
                                    ),
                                  )
                                : focusedBorder,
                          ),
                          onChanged: (_) {
                            if (_errorText != null) {
                              setState(() => _errorText = null);
                            }
                          },
                          onSubmitted: (_) => _submit(isAr),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Helper / error line — same slot, error takes priority.
              const SizedBox(height: 8),
              Text(
                hasError
                    ? _errorText!
                    : (isAr ? 'مثال: 99887766' : 'e.g. 99887766'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: hasError
                      ? cs.error
                      : cs.onSurface.withValues(alpha: 0.5),
                  fontSize: 12,
                  fontWeight: hasError ? FontWeight.w600 : FontWeight.w500,
                ),
              ),

              const SizedBox(height: 24),

              // Primary CTA — strong fill, slightly taller, moderate radius.
              SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: _saving ? null : () => _submit(isAr),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  child: _saving
                      ? SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: cs.onPrimary,
                          ),
                        )
                      : Text(isAr ? 'متابعة الحجز' : 'Continue booking'),
                ),
              ),

              // Secondary — neutral grey, clearly subordinate.
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: TextButton(
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        cs.onSurface.withValues(alpha: 0.62),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(isAr ? 'إلغاء' : 'Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookingPhoneConfirmBody extends StatelessWidget {
  const _BookingPhoneConfirmBody({required this.existingPhone});

  final String existingPhone;

  // Masks middle digits so only the first 4 are visible: "9988XXXX".
  String _mask(String phone) {
    final t = phone.trim();
    if (t.length < 8) return t;
    return '${t.substring(0, 4)}XXXX';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isAr ? 'تأكيد رقم التواصل' : 'Confirm your contact number',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isAr
                ? 'سنستخدم هذا الرقم للتواصل معك بخصوص الحجز.'
                : 'We will use this number to reach you about the booking.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.68),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outline.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.phone, size: 18, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isAr
                        ? 'رقمك: ${_mask(existingPhone)}'
                        : 'Your number: ${_mask(existingPhone)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: () => Navigator.of(context)
                  .pop(BookingPhoneConfirmChoice.continueBooking),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                isAr ? 'متابعة' : 'Continue',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop(BookingPhoneConfirmChoice.edit),
            child: Text(isAr ? 'تعديل الرقم' : 'Edit number'),
          ),
        ],
      ),
    );
  }
}

/// Reads `users/{uid}.phone` defensively. Returns a trimmed non-null string
/// (empty if missing / unreadable). Never throws — callers can treat any
/// non-empty result as "has a previously saved phone".
Future<String> readSavedUserPhone(String uid) async {
  try {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    if (!snap.exists) return '';
    final data = snap.data();
    if (data == null) return '';
    final raw = data['phone'];
    if (raw is String) return raw.trim();
    return '';
  } catch (_) {
    return '';
  }
}
