import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/public_auction_lot.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';
import 'package:aqarai_app/pages/auction_request_page.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';
import 'package:aqarai_app/app/property_route.dart';
import 'package:aqarai_app/widgets/add_auction_property_card.dart';

/// Browse the next upcoming auction and its lots (no bidding on this screen).
class AuctionsPage extends StatefulWidget {
  const AuctionsPage({super.key});

  @override
  State<AuctionsPage> createState() => _AuctionsPageState();
}

class _AuctionsPageState extends State<AuctionsPage> {
  late Stream<Auction?> _auctionStream;

  @override
  void initState() {
    super.initState();
    _auctionStream = AuctionService.watchNextUpcomingAuction();
  }

  Future<void> _reloadAuctions() async {
    setState(() {
      _auctionStream = AuctionService.watchNextUpcomingAuction();
    });
  }

  String _formatMoney(BuildContext context, double value) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = NumberFormat.currency(
      locale: locale,
      symbol: '',
      decimalDigits: value == value.roundToDouble() ? 0 : 3,
    );
    final suffix = Localizations.localeOf(context).languageCode == 'ar'
        ? ' د.ك'
        : ' KWD';
    return '${fmt.format(value)}$suffix';
  }

  String _formatDateTime(BuildContext context, DateTime dt) {
    final loc = Localizations.localeOf(context);
    final isAr = loc.languageCode == 'ar';
    final pattern = isAr ? 'EEEE، d MMMM yyyy — HH:mm' : 'EEE, MMM d, yyyy — HH:mm';
    return DateFormat(pattern, loc.toString()).format(dt.toLocal());
  }

  String _auctionStatusChipLabel(BuildContext context, Auction auction) {
    final loc = AppLocalizations.of(context)!;
    final now = DateTime.now();
    if (auction.status == AuctionStatus.live) return loc.auctionStatusLiveNow;
    if (now.isBefore(auction.startDate)) return loc.auctionStatusSoon;
    if (now.isBefore(auction.endDate)) return loc.auctionStatusLiveNow;
    return loc.auctionStatusSoon;
  }

  void _showAuctionTermsSheet(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(loc.auctionsTermsDialogTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AuctionTermsSection(
                  title: loc.auctionsTermsParticipationTitle,
                  body: loc.auctionsTermsParticipationBody,
                ),
                const SizedBox(height: 16),
                _AuctionTermsSection(
                  title: loc.auctionsTermsRegistrationTitle,
                  body: loc.auctionsTermsRegistrationBody,
                ),
                const SizedBox(height: 16),
                _AuctionTermsSection(
                  title: loc.auctionsTermsDepositTitle,
                  body: loc.auctionsTermsDepositBody,
                ),
                const SizedBox(height: 16),
                _AuctionTermsSection(
                  title: loc.auctionsTermsGeneralTitle,
                  body: loc.auctionsTermsGeneralBody,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(loc.cancel),
            ),
          ],
        );
      },
    );
  }

  void _openListing(BuildContext context, PublicAuctionLot lot) {
    context.pushPropertyDetails(
      propertyId: lot.listingDocumentId,
      auctionLotId: lot.id,
      auctionId: lot.auctionId,
      leadSource: DealLeadSource.direct,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.auctionsPageTitle),
        actions: [
          IconButton(
            tooltip: loc.retry,
            onPressed: _reloadAuctions,
            icon: const Icon(Icons.refresh_outlined),
          ),
        ],
      ),
      body: StreamBuilder<Auction?>(
        stream: _auctionStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                    const SizedBox(height: 16),
                    Text(
                      loc.auctionsLoadError,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _reloadAuctions,
                      child: Text(loc.retry),
                    ),
                  ],
                ),
              ),
            );
          }

          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final auction = snap.data;
          if (auction == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.event_busy_outlined,
                      size: 64,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      loc.auctionsEmptyTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      loc.auctionsEmptySubtitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AddAuctionPropertyCard(
                      onTap: () {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => const AuctionRequestPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _reloadAuctions,
            child: StreamBuilder<List<PublicAuctionLot>>(
              key: ValueKey<String>(auction.id),
              stream: LotService.watchPublicLotsForAuction(auction.id),
              builder: (context, lotsSnap) {
                final lotsLoading =
                    lotsSnap.connectionState == ConnectionState.waiting &&
                        !lotsSnap.hasData;
                final lots = lotsSnap.data ?? [];
                final lotsError = lotsSnap.hasError;

                void openAddProperty() {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const AuctionRequestPage(),
                    ),
                  );
                }

                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: _AuctionHeaderCard(
                          auction: auction,
                          statusLabel: _auctionStatusChipLabel(context, auction),
                          dateLine: loc.auctionsStartsAt(
                            _formatDateTime(context, auction.startDate),
                          ),
                          onShowTerms: () => _showAuctionTermsSheet(context),
                        ),
                      ),
                    ),
                    if (lotsLoading)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.28,
                          child: const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator(),
                            ),
                          ),
                        ),
                      )
                    else if (lotsError)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.22,
                          child: Center(
                            child: Text(
                              loc.auctionsLoadError,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      )
                    else if (lots.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 40,
                          ),
                          child: Text(
                            loc.auctionsLotsEmpty,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final lot = lots[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _LotCard(
                                  lot: lot,
                                  formatMoney: (v) => _formatMoney(context, v),
                                  viewLabel: loc.auctionsViewProperty,
                                  startingLabel: loc.auctionsStartingPriceLabel,
                                  minIncLabel: loc.auctionsMinIncrementLabel,
                                  onOpen: () => _openListing(context, lot),
                                ),
                              );
                            },
                            childCount: lots.length,
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        child: AddAuctionPropertyCard(onTap: openAddProperty),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _AuctionTermsSection extends StatelessWidget {
  const _AuctionTermsSection({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.45,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _AuctionHeaderCard extends StatelessWidget {
  const _AuctionHeaderCard({
    required this.auction,
    required this.statusLabel,
    required this.dateLine,
    required this.onShowTerms,
  });

  final Auction auction;
  final String statusLabel;
  final String dateLine;
  final VoidCallback onShowTerms;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desc = auction.description.trim();

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    auction.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(statusLabel),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    dateLine,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                desc,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: onShowTerms,
              child: Text(AppLocalizations.of(context)!.auctionsShowTermsButton),
            ),
          ],
        ),
      ),
    );
  }
}

class _LotCard extends StatelessWidget {
  const _LotCard({
    required this.lot,
    required this.formatMoney,
    required this.viewLabel,
    required this.startingLabel,
    required this.minIncLabel,
    required this.onOpen,
  });

  final PublicAuctionLot lot;
  final String Function(double) formatMoney;
  final String viewLabel;
  final String startingLabel;
  final String minIncLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = lot.image?.trim();
    final locationText = lot.location?.trim();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: imageUrl != null && imageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                          errorWidget: (context, url, error) => ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.home_work_outlined,
                              color: theme.colorScheme.outline,
                              size: 40,
                            ),
                          ),
                        )
                      : ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.home_work_outlined,
                            color: theme.colorScheme.outline,
                            size: 40,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      lot.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (locationText != null && locationText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.place_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              locationText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '$startingLabel: ${formatMoney(lot.startingPrice)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$minIncLabel: ${formatMoney(lot.minIncrement)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FilledButton(
                        onPressed: onOpen,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        child: Text(viewLabel),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
