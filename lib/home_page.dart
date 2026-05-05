// lib/home_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/widgets/search_box.dart';

import 'package:aqarai_app/pages/add_property_page.dart';
import 'package:aqarai_app/pages/my_ads_page.dart';
import 'package:aqarai_app/pages/valuation_page.dart';
import 'package:aqarai_app/pages/wanted_page.dart';
import 'package:aqarai_app/pages/admin_requests_page.dart';
import 'package:aqarai_app/pages/favorites_page.dart';
import 'package:aqarai_app/pages/assistant_page.dart';
import 'package:aqarai_app/pages/auctions_page.dart';
import 'package:aqarai_app/pages/daily_rent_page.dart';
import 'package:aqarai_app/pages/legal_pages.dart';
import 'package:aqarai_app/pages/contact_us_page.dart';
import 'package:aqarai_app/pages/notifications_page.dart';

import 'package:aqarai_app/app/locale_notifier.dart' show setAppLocale;
import 'package:aqarai_app/widgets/notifications_inbox_bell_button.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

import 'package:aqarai_app/widgets/smart_assistant_cta.dart';
import 'package:aqarai_app/widgets/featured_carousel.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/widgets/featured_wanted_carousel.dart';

import 'package:aqarai_app/services/auth_service.dart';
import 'package:flag/flag.dart';

/// علم بجانب خيار اللغة في القائمة (كويت للعربية، بريطانيا للإنجليزية)
Widget _languageFlagLeading(FlagsCode code) {
  return SizedBox(
    width: 40,
    height: 28,
    child: Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Flag.fromCode(
          code,
          height: 22,
          width: 32,
          fit: BoxFit.cover,
        ),
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool? _isAdmin;
  Stream<int>? _pendingStream;

  static const Color _bgColor = Color(0xFF0B0F1A);

  /// عداد قيد المراجعة = إعلانات + طلبات مطلوب + طلبات تقييم غير المعتمدة (للشارة الحمراء)
  static Stream<int> _createPendingCountStream() {
    final firestore = FirebaseFirestore.instance;
    final c = StreamController<int>.broadcast();
    var countProps = 0, countWanted = 0, countValuations = 0;
    void emit() => c.add(countProps + countWanted + countValuations);
    StreamSubscription? s1, s2, s3;
    s1 = firestore
        .collection('properties')
        .where('approved', isEqualTo: false)
        .snapshots()
        .listen((s) {
      countProps = s.docs.length;
      emit();
    });
    s2 = firestore
        .collection('wanted_requests')
        .where('approved', isEqualTo: false)
        .snapshots()
        .listen((s) {
      countWanted = s.docs.length;
      emit();
    });
    s3 = firestore
        .collection('valuations')
        .where('approved', isEqualTo: false)
        .snapshots()
        .listen((s) {
      countValuations = s.docs.length;
      emit();
    });
    c.onCancel = () {
      s1?.cancel();
      s2?.cancel();
      s3?.cancel();
    };
    return c.stream;
  }

  @override
  void initState() {
    super.initState();
    _loadAdminStatus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(
      const AssetImage('assets/images/kuwait_bridge_bg.png'),
      context,
    );
  }

  Future<void> _loadAdminStatus() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;
      setState(() => _isAdmin = false);
      return;
    }

    final token = await user.getIdTokenResult(true);
    final isAdmin = AuthService.isAdminFromClaims(token.claims);

    if (!mounted) return;

    setState(() {
      _isAdmin = isAdmin;

      if (isAdmin) {
        _pendingStream = _createPendingCountStream();
      }
    });
  }

  void _openQuickMenu() {
    final loc = AppLocalizations.of(context)!;
    final currentCode = Localizations.localeOf(context).languageCode;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return ListView(
          padding: const EdgeInsets.only(bottom: 8),
          shrinkWrap: true,
          children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  loc.quickMenuTitle,
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: Text(loc.notificationsQuickMenu),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NotificationsPage()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.favorite_border),
                title: Text(loc.favorites),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FavoritesPage()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.gavel_outlined),
                title: Text(loc.auctionsPageTitle),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AuctionsPage()),
                  );
                },
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  loc.languageLabel,
                  style: Theme.of(sheetContext).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              ListTile(
                leading: _languageFlagLeading(FlagsCode.KW),
                title: Text(loc.languageArabic),
                trailing: currentCode == 'ar'
                    ? Icon(Icons.check, color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () {
                  setAppLocale(const Locale('ar'));
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: _languageFlagLeading(FlagsCode.GB),
                title: Text(loc.languageEnglish),
                trailing: currentCode == 'en'
                    ? Icon(Icons.check, color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () {
                  setAppLocale(const Locale('en'));
                  Navigator.pop(sheetContext);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.support_agent_outlined),
                title: Text(loc.contactUsTitle),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ContactUsPage()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.gavel_outlined),
                title: Text(loc.quickMenuLegal),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LegalScreen()),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;

    return Scaffold(
      backgroundColor: _bgColor,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/kuwait_bridge_bg.png',
              fit: BoxFit.cover,
            ),
          ),

          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x22000000),
                  Color(0x66000000),
                  Color(0xDD000000),
                ],
              ),
            ),
          ),

          // المحتوى
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 152),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 40),

                      const AqarSearchBox(),

                      const SizedBox(height: 14),

                      SmartAssistantCta(
                        title: locale == 'ar'
                            ? 'شقق بالأحياء — إيجار يومي'
                            : 'Area apartments — daily rent',
                        subtitle: locale == 'ar'
                            ? 'شقق للإيجار اليومي أو الشهري في السالمية، الجابرية، وحول الكويت'
                            : 'Daily or monthly apartment rentals across Kuwait neighborhoods.',
                        leadingIcon: Icons.calendar_today_outlined,
                        trailingIcon: Icons.chevron_right_rounded,
                        accentColor: const Color(0xFF0EA5E9),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => const DailyRentPage(),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 12),

                      SmartAssistantCta(
                        title: loc.smartAssistantCtaTitle,
                        subtitle: loc.smartAssistantCtaSubtitle,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AssistantPage(),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 12),

                      SmartAssistantCta(
                        title: loc.auctionsPageTitle,
                        subtitle: loc.auctionsHomeSubtitle,
                        leadingIcon: Icons.gavel_rounded,
                        trailingIcon: Icons.chevron_right_rounded,
                        accentColor: const Color(0xFFB45309),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AuctionsPage(),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 20),

                      // ⭐ مميزة للبيع (بدون شاليهات)
                      FeaturedCarousel(
                        serviceType: 'sale',
                        title: locale == 'ar'
                            ? "عقارات مميزة للبيع"
                            : "Featured for Sale",
                        listingCategory: ListingCategory.normal,
                      ),

                      const SizedBox(height: 20),

                      // ⭐ مميزة للإيجار (بدون شاليهات)
                      FeaturedCarousel(
                        serviceType: 'rent',
                        title: locale == 'ar'
                            ? "عقارات مميزة للإيجار"
                            : "Featured for Rent",
                        listingCategory: ListingCategory.normal,
                      ),

                      const SizedBox(height: 20),

                      // ⭐ شاليهات مميزة للبيع
                      // Restored from the deleted `ChaletsPage`; previously
                      // filtered out of the two carousels above because
                      // `listingCategory.normal` excludes chalets.
                      FeaturedCarousel(
                        serviceType: 'sale',
                        title: locale == 'ar'
                            ? "شاليهات مميزة للبيع"
                            : "Featured Chalets for Sale",
                        listingCategory: ListingCategory.chalet,
                      ),

                      const SizedBox(height: 20),

                      // ⭐ شاليهات مميزة للإيجار
                      FeaturedCarousel(
                        serviceType: 'rent',
                        title: locale == 'ar'
                            ? "شاليهات مميزة للإيجار"
                            : "Featured Chalets for Rent",
                        listingCategory: ListingCategory.chalet,
                      ),

                      const SizedBox(height: 20),

                      // ⭐ مطلوب مميز
                      const FeaturedWantedCarousel(),

                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom Navigation — كبسولة عائمة احترافية
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: _HomeFloatingBottomNav(loc: loc),
            ),
          ),

          // القائمة: المفضلة + اللغة
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 14, right: 14),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openQuickMenu,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.35),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withOpacity(0.35),
                        width: 1,
                      ),
                    ),
                    child: const Icon(
                      Icons.menu,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 14, left: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isAdmin == true)
                      StreamBuilder<int>(
                        stream: _pendingStream,
                        builder: (context, snap) {
                          final count = snap.data ?? 0;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const AdminRequestsPage(),
                                ),
                              );
                            },
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.35),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.35),
                                  width: 1,
                                ),
                              ),
                              child: Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.center,
                                children: [
                                  const Icon(
                                    Icons.admin_panel_settings,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                  if (count > 0)
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: Container(
                                        width: 12,
                                        height: 12,
                                        decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    if (_isAdmin == true) const SizedBox(width: 8),
                    const NotificationsInboxBellButton(isOnDarkBackground: true),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// كبسولة عائمة سفلية — زر أضف عقار بارز (نسام)، وباقي الأقسام في صف تحته داخل الكبسولة
class _HomeFloatingBottomNav extends StatelessWidget {
  final AppLocalizations loc;

  const _HomeFloatingBottomNav({required this.loc});

  static const double _fabSize = 56;
  /// مسافة فوق الكبسولة ليبرز الجزء العلوي من الزر دون قصّ
  static const double _humpTopSpace = 26;
  /// عرض الحيز المركزي (يتساوى مع موضع الـ FAB)
  static const double _centerSlotWidth = _fabSize + 22;

  @override
  Widget build(BuildContext context) {
    // الهامش السفلي فقط — SafeArea في HomePage يطبّق بالفعل مسافة الـ home indicator
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: _humpTopSpace),
              Container(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(36),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                // مجموعتان متوازنتان: 2 | فراغ الـ FAB | 2 (المفضلة انتقلت لقائمة أعلى اليمين)
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Row(
                        children: [
                          Expanded(
                            child: _FloatingNavItem(
                              icon: Icons.list_outlined,
                              label: loc.myAds,
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyAdsPage())),
                            ),
                          ),
                          Expanded(
                            child: _FloatingNavItem(
                              icon: Icons.bar_chart_outlined,
                              label: loc.valuation,
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ValuationPage())),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: _centerSlotWidth),
                    Expanded(
                      flex: 3,
                      child: Row(
                        children: [
                          Expanded(
                            child: _FloatingNavItem(
                              icon: Icons.gavel_outlined,
                              label: loc.auctionsPageTitle,
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuctionsPage())),
                            ),
                          ),
                          Expanded(
                            child: _FloatingNavItem(
                              icon: Icons.campaign_outlined,
                              label: loc.wanted,
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WantedPage())),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            top: _humpTopSpace - _fabSize / 2,
            child: Center(
              child: _FloatingNavCenterAdd(
                fabSize: _fabSize,
                label: loc.addProperty,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddPropertyPage())),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _FloatingNavItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const iconSize = 24.0;
    const fontSize = 10.0;
    final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: Colors.black87,
          height: 1.15,
        ) ??
        const TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: Colors.black87,
          height: 1.15,
        );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, color: Colors.black87, size: iconSize),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingNavCenterAdd extends StatelessWidget {
  final double fabSize;
  final String label;
  final VoidCallback onTap;

  const _FloatingNavCenterAdd({
    required this.fabSize,
    required this.label,
    required this.onTap,
  });

  static const Color _navy = Color(0xFF101046);

  @override
  Widget build(BuildContext context) {
    final iconSize = fabSize * 0.48;
    return Material(
      color: Colors.transparent,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(fabSize),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: fabSize,
                height: fabSize,
                decoration: BoxDecoration(
                  color: _navy,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Icon(Icons.add, color: Colors.white, size: iconSize),
              ),
              const SizedBox(height: 5),
              SizedBox(
                width: fabSize + 14,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                        height: 1.15,
                      ) ??
                      const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                        height: 1.15,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

