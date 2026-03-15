// lib/home_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/widgets/search_box.dart';

import 'package:aqarai_app/pages/chalets_page.dart';
import 'package:aqarai_app/pages/add_property_page.dart';
import 'package:aqarai_app/pages/my_ads_page.dart';
import 'package:aqarai_app/pages/valuation_page.dart';
import 'package:aqarai_app/pages/wanted_page.dart';
import 'package:aqarai_app/pages/admin_requests_page.dart';
import 'package:aqarai_app/pages/favorites_page.dart';

import 'package:aqarai_app/app/locale_notifier.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

import 'package:aqarai_app/widgets/featured_carousel.dart';
import 'package:aqarai_app/widgets/featured_wanted_carousel.dart';

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
    final isAdmin = token.claims?['admin'] == true;

    if (!mounted) return;

    setState(() {
      _isAdmin = isAdmin;

      if (isAdmin) {
        _pendingStream = _createPendingCountStream();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: _bgColor,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
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
                  padding: const EdgeInsets.only(bottom: 160),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 40),

                      const AqarSearchBox(),

                      const SizedBox(height: 20),

                      // ⭐ مميزة للبيع (بدون شاليهات)
                      FeaturedCarousel(
                        serviceType: 'sale',
                        title: locale == 'ar'
                            ? "عقارات مميزة للبيع"
                            : "Featured for Sale",
                        excludeType: 'chalet',
                      ),

                      const SizedBox(height: 20),

                      // ⭐ مميزة للإيجار (بدون شاليهات)
                      FeaturedCarousel(
                        serviceType: 'rent',
                        title: locale == 'ar'
                            ? "عقارات مميزة للإيجار"
                            : "Featured for Rent",
                        excludeType: 'chalet',
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

          // Bottom Navigation
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: _bgColor,
              padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset + 12),
              child: SizedBox(
                height: 165,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.bottomCenter,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 74,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(36),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 12),
                          ],
                        ),
                        child: Row(
                        children: [
                          Expanded(
                            child: _BottomItem(
                              icon: Icons.list,
                              label: loc.myAds,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const MyAdsPage(),
                                  ),
                                );
                              },
                            ),
                          ),
                          Expanded(
                            child: _BottomItem(
                              icon: Icons.bar_chart,
                              label: loc.valuation,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ValuationPage(),
                                  ),
                                );
                              },
                            ),
                          ),
                          Expanded(child: const SizedBox.shrink()),
                          Expanded(
                            child: _BottomItem(
                              icon: Icons.beach_access,
                              label: loc.chalets,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ChaletsPage(),
                                  ),
                                );
                              },
                            ),
                          ),
                          Expanded(
                            child: _BottomItem(
                              icon: Icons.campaign,
                              label: loc.wanted,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const WantedPage(),
                                  ),
                                );
                              },
                            ),
                          ),
                          Expanded(
                            child: _BottomItem(
                              icon: Icons.favorite,
                              label: loc.favorites,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const FavoritesPage(),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                        ),
                    ),

                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 94,
                      child: Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AddPropertyPage(),
                              ),
                            );
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                loc.addProperty,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                width: 56,
                                height: 56,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF101046),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black38,
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.add,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // أزرار فوق المحتوى حتى تستقبل الضغطات (زر اللغة + طلبات الأدمن)
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 14, right: 14),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: toggleAppLocale,
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
                      Icons.language,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_isAdmin == true)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 14, left: 14),
                  child: StreamBuilder<int>(
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
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BottomItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BottomItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.black87),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

