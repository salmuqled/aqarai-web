import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/auth/login_page.dart';
import 'package:aqarai_app/widgets/chalet_booking_widget.dart';

/// Full-screen sticky booking bar (Airbnb-style) meant for `Scaffold.bottomNavigationBar`.
///
/// Rebuilds are scoped with [ValueListenableBuilder] / [ListenableBuilder] so the
/// shell (Material, padding, per-night label) is not rebuilt on every calendar tick.
class BookingBar extends StatelessWidget {
  const BookingBar({
    super.key,
    required this.controller,
    required this.pricePerNight,
    this.currencyCode = 'KWD',
  });

  final ChaletBookingController controller;
  final double pricePerNight;
  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
    final cs = Theme.of(context).colorScheme;
    final perNightLabel = '${fmt.format(pricePerNight)} $currencyCode';

    return Material(
      elevation: 18,
      shadowColor: cs.shadow.withValues(alpha: 0.22),
      color: cs.surfaceContainerLowest,
      surfaceTintColor: cs.surfaceTint,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.14)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _BarMetric(
                      label: isAr ? 'لليلة' : 'Per night',
                      value: perNightLabel,
                      align: TextAlign.start,
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: controller.nightsVN,
                      builder: (context, nights, _) {
                        return _AnimatedBarMetric(
                          label: isAr ? 'ليالي' : 'Nights',
                          value: '$nights',
                          valueKey: nights,
                          align: TextAlign.center,
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<double>(
                      valueListenable: controller.totalPriceVN,
                      builder: (context, total, _) {
                        final totalLabel = '${fmt.format(total)} $currencyCode';
                        return _AnimatedBarMetric(
                          label: isAr ? 'الإجمالي' : 'Total',
                          value: totalLabel,
                          valueKey: totalLabel,
                          align: TextAlign.end,
                        );
                      },
                    ),
                  ),
                ],
              ),
              ValueListenableBuilder<bool>(
                valueListenable: controller.isProvisionalVN,
                builder: (context, provisional, _) {
                  if (!provisional) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      isAr
                          ? 'معاينة — اضغط تاريخ المغادرة لإنهاء الاختيار'
                          : 'Preview — tap check-out to confirm your stay',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.primary.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              StreamBuilder<User?>(
                stream: FirebaseAuth.instance.authStateChanges(),
                initialData: FirebaseAuth.instance.currentUser,
                builder: (context, authSnap) {
                  final loggedIn = authSnap.data != null;
                  return ListenableBuilder(
                    listenable: controller.barCtaListenable,
                    builder: (context, _) {
                      final canBook = controller.canBookVN.value;
                      final submitting = controller.submittingVN.value;
                      final canAct = loggedIn && canBook && !submitting;

                      Widget label;
                      if (submitting && loggedIn) {
                        label = SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: cs.onPrimary,
                          ),
                        );
                      } else if (!loggedIn) {
                        label = Text(
                          isAr ? 'سجّل الدخول للحجز' : 'Login to book',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        );
                      } else {
                        label = Text(
                          isAr ? 'احجز الآن' : 'Book now',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        );
                      }

                      return FilledButton(
                        onPressed: submitting
                            ? null
                            : (!loggedIn
                                  ? () {
                                      Navigator.of(context).push<void>(
                                        MaterialPageRoute<void>(
                                          builder: (_) => const LoginPage(),
                                        ),
                                      );
                                    }
                                  : (canBook ? controller.submit : null)),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: canAct ? 2.5 : 0,
                        ),
                        child: label,
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarMetric extends StatelessWidget {
  const _BarMetric({
    required this.label,
    required this.value,
    required this.align,
  });

  final String label;
  final String value;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurface.withValues(alpha: 0.55),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );
    final valueStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
    );

    return Column(
      crossAxisAlignment: align == TextAlign.end
          ? CrossAxisAlignment.end
          : align == TextAlign.center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(label, style: labelStyle, textAlign: align),
        const SizedBox(height: 2),
        Text(
          value,
          style: valueStyle?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          textAlign: align,
        ),
      ],
    );
  }
}

class _AnimatedBarMetric extends StatelessWidget {
  const _AnimatedBarMetric({
    required this.label,
    required this.value,
    required this.valueKey,
    required this.align,
  });

  final String label;
  final String value;
  final Object valueKey;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurface.withValues(alpha: 0.55),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );
    final valueStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
    );

    final crossAxis = align == TextAlign.end
        ? CrossAxisAlignment.end
        : align == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    return Column(
      crossAxisAlignment: crossAxis,
      children: [
        Text(label, style: labelStyle, textAlign: align),
        const SizedBox(height: 2),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) {
            return FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.12),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            );
          },
          child: Text(
            value,
            key: ValueKey<Object>(valueKey),
            style: valueStyle?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            textAlign: align,
          ),
        ),
      ],
    );
  }
}
