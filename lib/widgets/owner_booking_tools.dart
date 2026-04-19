import 'package:flutter/material.dart';

import 'package:aqarai_app/pages/owner_property_bookings_page.dart';
import 'package:aqarai_app/widgets/chalet_booking_widget.dart';

/// Owner-only tools on chalet rent listing details (no guest booking surface).
class OwnerBookingTools extends StatelessWidget {
  const OwnerBookingTools({super.key, required this.propertyId});

  final String propertyId;

  void _openAvailability(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: DraggableScrollableSheet(
            initialChildSize: 0.72,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scrollController) {
              return ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Text(
                    isAr ? 'إدارة التوفر' : 'Manage availability',
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 12),
                  ChaletOwnerAvailabilityTools(propertyId: propertyId),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _openBookings(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OwnerPropertyBookingsPage(propertyId: propertyId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'أدوات الحجز (مالك)' : 'Booking tools (owner)',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => _openAvailability(context),
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(isAr ? 'إدارة التوفر' : 'Manage availability'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _openBookings(context),
              icon: const Icon(Icons.event_note_outlined),
              label: Text(isAr ? 'عرض الحجوزات' : 'View bookings'),
            ),
          ],
        ),
      ),
    );
  }
}
