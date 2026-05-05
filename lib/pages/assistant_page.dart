// lib/pages/assistant_page.dart
//
// =============================================================================
// ARCHITECTURE: AI Real Estate Agent (logic only; no UI changes)
// =============================================================================
// State: _currentFilters (Map), _lastResults (List<QueryDocumentSnapshot>).
//
// Flow in _sendMessage():
//   1) AiBrainService.analyzeMessage(..., top3LastResults: last 3 shown listing memory: propertyId, price, area, type, rank)
//   2) If intent == greeting -> append friendly message, stop
//   3) If reset_filters == true -> clear _currentFilters and _lastResults
//   4) Merge params_patch into _currentFilters
//   5) If is_complete == false -> append clarifying_questions, stop
//   6) Run Firestore search: ConversationalSearchService (areaCode, type, serviceType, budget -> price <= budget)
//   7) Save results to _lastResults
//   8) Save buyer interest (UserInterestService) if user signed in and filters non-empty; ignore errors
//   9) Rank + compose in one call: aqaraiAgentRankAndCompose (rankAndComposeMarketingReply), append reply
//   10) No-results fallback sets _awaitingNotifyConsent; short "yes" (نعم/اي/تمام/ok) saves interest again + confirmation
//
// Step-by-step tests:
//   a) "السلام عليكم" -> intent=greeting, append friendly message, stop
//   b) "ابي بيت للبيع بالقادسية" -> params_patch, search (areaCode, type, serviceType), top3 -> compose, append
//   c) "ابي أرخص" -> params_patch.budget or is_complete=false + clarifying_questions
//   d) "كم غرفة؟" -> clarifying_questions or params_patch.bedrooms
//   e) "غير المنطقة للنزهة" -> reset_filters=true, clear state, params_patch.areaCode=nuzha, search
// =============================================================================

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:aqarai_app/services/ai_brain_service.dart';
import 'package:aqarai_app/services/chat_analytics_service.dart';
import 'package:aqarai_app/services/conversational_search_service.dart';
import 'package:aqarai_app/services/user_interest_service.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/notification_service.dart';
import 'package:aqarai_app/services/user_activity_service.dart';
import 'package:aqarai_app/widgets/chat_bubble.dart';
import 'package:aqarai_app/app/property_route.dart';
import 'package:aqarai_app/widgets/listing_card.dart';
import 'package:aqarai_app/widgets/banned_user_session_gate.dart';
import 'package:aqarai_app/widgets/notifications_inbox_bell_button.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/utils/property_area_display.dart';
import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';

/// إعلان يُعرض في نتائج المساعد (معتمد وظاهر للعميل).
bool _listingVisibleForAssistantSearch(Map<String, dynamic> data) {
  return listingDataIsPubliclyDiscoverable(data);
}

/// No listings after search (+ optional findSimilar); offline hint + traditional search (X).
const String _assistantNoResultsAr =
    'بنفس المواصفات بالضبط ما نزل شي هالحين — بس أقدر أشتغل معك على خيارين سريعين 👇\n\n'
    '• أوسّع لك المنطقة شوي لمناطق مجاورة بنفس المزايا.\n'
    '• أو أسجّل اهتمامك وأرسل لك إشعار أول ما ينزل مطابق لطلبك.\n\n'
    'قل لي: تبي أوسّع المنطقة، أعدّل الميزانية، ولا أتابع لك لين يطلع الجديد؟';

const String _assistantNoResultsEn =
    'Nothing matches your exact spec right now — but I can help you move fast 👇\n\n'
    '• Widen the area to nearby spots with the same perks.\n'
    '• Or save your interest and I\'ll ping you the moment something matching is listed.\n\n'
    'Tell me: widen the area, tweak the budget, or track it for you?';

class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage>
    with WidgetsBindingObserver {
  static bool _webCaptionLinkHandled = false;

  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  bool _assistantTyping = false;
  bool _isAr = true;
  bool _fcmSetupDone = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(UserActivityService.recordActivity(reason: 'app_resume'));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // Best-effort drain of buffered analytics when the app backgrounds.
      // Never awaited — lifecycle callbacks must return promptly.
      unawaited(ChatAnalyticsService().flushNow());
    }
  }

  /// فلاتر البحث الحالية (من الـ Agent)
  Map<String, dynamic> _currentFilters = {};

  /// نتائج آخر استعلام — للرد على المتابعة ولتأليف الرد التسويقي
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _lastResults = [];

  /// True after a no-results reply that offered to notify; next short confirmation saves interest explicitly.
  bool _awaitingNotifyConsent = false;

  /// Area-code → nearby area codes, auto-derived from the governorate
  /// structure ([governoratesAndAreasAr] + [areaArToEn]). Any area that lives
  /// in a governorate gets its siblings from the same governorate as the
  /// default nearby-set. This gives Kuwait-wide coverage without a hand-kept
  /// table — every future area addition to the governorate data shows up
  /// here automatically.
  ///
  /// Caveats:
  /// - Only siblings in the same governorate are returned (no cross-gov
  ///   cluster like "south surra ↔ north surra").
  /// - Up to 6 siblings per area; we don't try to pick the geographically
  ///   closest ones since we don't ship coordinates.
  /// - If an area name has no English mapping in [areaArToEn] we skip it so
  ///   the stored `areaCode` stays consistent with what search expects.
  static final Map<String, List<String>> _nearbyAreaCodes = _buildNearbyAreaCodes();

  static Map<String, List<String>> _buildNearbyAreaCodes() {
    String code(String s) {
      var v = s.trim().toLowerCase();
      v = v.replaceAll(RegExp(r'\s+'), '_');
      v = v.replaceAll('-', '_');
      v = v.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
      v = v.replaceAll(RegExp(r'_+'), '_');
      v = v.replaceAll(RegExp(r'^_+|_+$'), '');
      return v;
    }

    const int maxSiblings = 6;
    final out = <String, List<String>>{};
    for (final entry in governoratesAndAreasAr.entries) {
      final codes = <String>[];
      for (final ar in entry.value) {
        final en = areaArToEn[ar];
        if (en == null || en.isEmpty) continue;
        final c = code(en);
        if (c.isEmpty) continue;
        if (!codes.contains(c)) codes.add(c);
      }
      for (final c in codes) {
        final siblings = <String>[];
        for (final other in codes) {
          if (other == c) continue;
          siblings.add(other);
          if (siblings.length >= maxSiblings) break;
        }
        if (siblings.isNotEmpty) out[c] = siblings;
      }
    }
    return out;
  }

  /// Below this threshold the Smart Suggestions Engine is invoked to generate
  /// alternative filters (shift dates, bump budget, widen area). Must stay in
  /// sync with `SMART_SUGGESTIONS_WEAK_THRESHOLD` on the server.
  static const int _weakResultThreshold = 3;

  /// Same area labels as listing cards ([areaArToEn] + [propertyLocationCode]).
  String _areaUiLabel(String areaCode) =>
      areaLabelForCode(areaCode, arabic: _isAr);

  static const String _welcomeAr =
      'هلا والله 👋 أنا مساعدك في عقار AI. أقدر أطلع لك شاليه للويكند، شقة للإيجار، بيت أو عمارة للتمليك، محل، مكتب، أو أرض.\nقل لي نوع العقار والمنطقة وخلني أشيك لك على المتاح 👌';
  static const String _welcomeEn =
      'Hi there 👋 I\'m your AqarAi assistant. I can pull chalets for the weekend, apartments for rent, houses or buildings for sale, shops, offices, or land.\nTell me the type and area and I\'ll line up the best options for you.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
      unawaited(UserActivityService.recordActivity());
      _tryOpenPropertyFromWebCaptionLink();
    });
  }

  /// Web: `?id=propertyId&cid=A` opens details once (Instagram / bio link).
  void _tryOpenPropertyFromWebCaptionLink() {
    if (!kIsWeb || _webCaptionLinkHandled) return;
    final u = Uri.base;
    final id = u.queryParameters['id']?.trim();
    final cid = u.queryParameters['cid']?.trim();
    if (id == null || id.isEmpty || !mounted) return;
    _webCaptionLinkHandled = true;
    if (!mounted) return;
    context.pushPropertyDetails(
      propertyId: id,
      captionTrackingId:
          (cid != null && cid.isNotEmpty) ? cid : null,
      leadSource: DealLeadSource.direct,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_messages.isEmpty) {
      _isAr = Localizations.localeOf(context).languageCode == 'ar';
      _messages.add(ChatMessage(
        text: _isAr ? _welcomeAr : _welcomeEn,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    }
    if (!_fcmSetupDone) {
      _fcmSetupDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final user = FirebaseAuth.instance.currentUser;
        final claims = (await user?.getIdTokenResult(true))?.claims;
        final isAdmin = AuthService.isAdminFromClaims(claims);
        if (mounted) {
          await NotificationService.setup(
            context,
            subscribeAdmin: isAdmin == true,
          );
        }
      });
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage([String? prefilledText]) async {
    final text = (prefilledText?.trim() ?? _controller.text.trim());
    if (text.isEmpty || _isLoading) return;

    _controller.clear();
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true, timestamp: DateTime.now()));
      _isLoading = true;
      _assistantTyping = true;
    });
    _scrollToBottom();

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _appendReply(_isAr ? 'سجّل دخول عشان أبحث لك.' : 'Sign in to search.');
      return;
    }

    try {
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        _appendReply(_isAr ? 'ما قدرت أتحقق من الدخول. جرّب مرة ثانية.' : 'Could not verify sign-in. Try again.');
        return;
      }

      if (_awaitingNotifyConsent) {
        if (_isAffirmativeNotifyConsent(text)) {
          try {
            await UserInterestService().saveInterest(
              userId: user.uid,
              filters: Map<String, dynamic>.from(_currentFilters),
            );
          } catch (e, st) {
            debugPrint(
              'Error in AssistantPage._sendMessage saveInterest (notify consent): $e\n$st',
            );
          }
          _awaitingNotifyConsent = false;
          _appendReply(_isAr
              ? 'تمام 👌 راح أبلغك أول ما ينزل شيء مناسب لك'
              : 'Got it 👌 I\'ll notify you as soon as something suitable is listed.');
          return;
        }
        _awaitingNotifyConsent = false;
      }

      final aiBrain = AiBrainService();
      final lastMessages = _last8Messages();

      final result = await aiBrain.analyzeMessage(
        message: text,
        chatHistory: lastMessages,
        currentFilters: _currentFilters.isEmpty ? null : Map<String, dynamic>.from(_currentFilters),
        top3LastResults: _top3MemoryForAnalyze(),
        locale: _isAr ? 'ar' : 'en',
      );

      final intent = result['intent']?.toString() ?? 'general_question';
      final paramsPatch = result['params_patch'] is Map ? Map<String, dynamic>.from(result['params_patch'] as Map) : <String, dynamic>{};
      final resetFilters = result['reset_filters'] == true;
      final isComplete = result['is_complete'] == true;
      final clarifyingQuestions = result['clarifying_questions'] is List
          ? (result['clarifying_questions'] as List).map((e) => e.toString()).toList()
          : <String>[];

      if (intent == 'greeting') {
        final greetingReply = result['greeting_reply']?.toString();
        final reply = (greetingReply != null && greetingReply.isNotEmpty)
            ? greetingReply
            : (_isAr ? 'وعليكم السلام.' : 'Hi.');
        _appendReply(reply);
        return;
      }

      // High-intent booking shortcut. Server ships a warm canned reply that
      // confirms and points the user at the tap-through flow. No search,
      // no filter changes — this is the moment to CLOSE, not to re-query.
      if (intent == 'booking_intent') {
        final canned = result['greeting_reply']?.toString();
        final reply = (canned != null && canned.isNotEmpty)
            ? canned
            : (_isAr
                ? 'أبشر 👌 اختر العقار من الخيارات اللي عرضتها لك وادخل على صفحة التفاصيل، أقدر أكمل معك خطوات الحجز من هناك.'
                : "Perfect 👌 open the listing from the options above and tap through — I'll walk you through the booking steps from there.");
        _appendReply(reply);
        return;
      }

      // Hesitation — respond with space, not pressure.
      if (intent == 'hesitation') {
        final canned = result['greeting_reply']?.toString();
        final reply = (canned != null && canned.isNotEmpty)
            ? canned
            : (_isAr
                ? 'خذ راحتك 👌 ما فيه استعجال. إذا حاب أرتب لك أفضل خيار حسب ميزانيتك قل لي.'
                : "Take your time 👌 no rush. If you'd like, I can line up the best option for your budget — just say the word.");
        _appendReply(reply);
        return;
      }

      // NOTE: `top_demand_chalets` is intentionally not handled here. The
      // AI chat always serves the user's concrete specs (area, budget,
      // dates, features) through the normal search flow below. If the
      // backend ever returns that deprecated intent, it falls through and
      // the standard branch asks for the customer's requirements.

      if (resetFilters) {
        if (!mounted) return;
        setState(() {
          _currentFilters = {};
          _lastResults = [];
        });
      }

      for (final e in paramsPatch.entries) {
        if (e.value != null) {
          _currentFilters[e.key] = e.value;
        }
      }

      final referencedPropertyId = result['referenced_property_id']?.toString().trim();
      if (intent == 'reference_listing' &&
          referencedPropertyId != null &&
          referencedPropertyId.isNotEmpty) {
        final idx = _lastResults.indexWhere((d) => d.id == referencedPropertyId);
        if (idx < 0) {
          _appendReply(_isAr
              ? 'ما لقيت نفس العقار في القائمة الحالية. جرّب تبحث مرة ثانية أو اختر من النتائج الظاهرة.'
              : 'That listing isn\'t in the current results anymore. Try searching again or pick from the list above.');
          return;
        }
        final chosen = _lastResults[idx];
        final chosenData = chosen.data();
        if (!mounted) return;
        setState(() {
          final ac = chosenData['areaCode']?.toString().trim();
          if (ac != null && ac.isNotEmpty) _currentFilters['areaCode'] = ac;
          final ty = chosenData['type']?.toString().trim();
          if (ty != null && ty.isNotEmpty) _currentFilters['type'] = ty;
          final st = chosenData['serviceType']?.toString().trim();
          if (st != null && st.isNotEmpty) _currentFilters['serviceType'] = st;
          final rest = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(_lastResults);
          rest.removeAt(idx);
          _lastResults = [chosen, ...rest];
        });
        try {
          final interestUser = FirebaseAuth.instance.currentUser;
          if (interestUser != null && _currentFilters.isNotEmpty) {
            await UserInterestService().saveInterest(
              userId: interestUser.uid,
              filters: _currentFilters,
            );
          }
        } catch (e, st) {
          debugPrint(
            'Error in AssistantPage._sendMessage saveInterest (reference_listing): $e\n$st',
          );
        }
        final areaCodeRef = _currentFilters['areaCode']?.toString().trim() ?? '';
        final userBudgetRef = _currentFilters['budget'] is num
            ? (_currentFilters['budget'] as num).toDouble()
            : (_currentFilters['budget'] != null ? double.tryParse(_currentFilters['budget'].toString()) : null);
        final propsForRank = _buildPropsForRank(_lastResults);
        final List<Map<String, dynamic>> top3ListRef;
        var refReply = '';
        if (propsForRank.isNotEmpty) {
          final refOut = await aiBrain.rankAndComposeMarketingReply(
            properties: propsForRank,
            requestedAreaCode: areaCodeRef,
            nearbyAreaCodes: const [],
            userBudget: userBudgetRef,
            isAr: _isAr,
            userAskedForMore: false,
            isNearbyFallback: false,
            requestedAreaLabel: '',
            rawMessage: text,
            preferListingIdFirst: referencedPropertyId,
          );
          top3ListRef = refOut.top3;
          refReply = refOut.reply.trim();
        } else {
          top3ListRef = [
            <String, dynamic>{
              'id': chosen.id,
              'areaAr': chosenData['areaAr'],
              'areaEn': chosenData['areaEn'],
              'type': chosenData['type'],
              'price': chosenData['price'],
              'size': chosenData['size'],
              'features': <String, bool>{
                'hasElevator': (chosenData['hasElevator'] ?? false) == true,
                'hasCentralAC': (chosenData['hasCentralAC'] ?? false) == true,
                'hasSplitAC': (chosenData['hasSplitAC'] ?? false) == true,
                'hasMaidRoom': (chosenData['hasMaidRoom'] ?? false) == true,
                'hasDriverRoom': (chosenData['hasDriverRoom'] ?? false) == true,
                'hasLaundryRoom': (chosenData['hasLaundryRoom'] ?? false) == true,
                'hasGarden': (chosenData['hasGarden'] ?? false) == true,
                'hasPoolIndoor': (chosenData['hasPoolIndoor'] ?? false) == true,
                'hasPoolOutdoor': (chosenData['hasPoolOutdoor'] ?? false) == true,
                'isBeachfront': (chosenData['isBeachfront'] ?? false) == true,
              },
            },
          ];
          refReply = (await aiBrain.composeMarketingReply(
            top3Results: top3ListRef,
            isAr: _isAr,
            userAskedForMore: false,
            isNearbyFallback: false,
            requestedAreaLabel: '',
            rawMessage: text,
          ))
              .reply
              .trim();
        }
        if (top3ListRef.isNotEmpty && refReply.isEmpty) {
          refReply = _isAr
              ? 'أبشر، لقيت لك كم خيار مرتّب 👇 قل لي إذا تبي أركّز على وحدة منهم.'
              : 'Here are a few solid options for you 👇 tell me if you want me to focus on one.';
        }
        final areaNameRef =
            areaCodeRef.isNotEmpty ? _areaUiLabel(areaCodeRef) : null;
        final propertyTypeRef = _currentFilters['type']?.toString().trim();
        final serviceTypeRef = _currentFilters['serviceType']?.toString().trim();
        final refSuggestions = _buildSmartSuggestions(
          area: areaNameRef,
          areaCodes: _activeAreaCodesFromFilters(),
          propertyType: propertyTypeRef?.isNotEmpty == true ? propertyTypeRef : null,
          serviceType: serviceTypeRef?.isNotEmpty == true ? serviceTypeRef : null,
          isAr: _isAr,
        ).map((s) => SuggestionChip.text(s)).toList();
        final refReplyResults = _enrichResultsWithFullDocs(
          top3ListRef.take(3).map((e) => Map<String, dynamic>.from(e)).toList(),
          _lastResults,
        );
        _awaitingNotifyConsent = false;
        _appendReply(
          refReply,
          results: refReplyResults,
          suggestions: refSuggestions.isNotEmpty ? refSuggestions : null,
        );
        return;
      }

      if (!isComplete) {
        final msg = clarifyingQuestions.isNotEmpty
            ? clarifyingQuestions.join('\n')
            : (_isAr
                ? 'حياك الله 👌 عطني فكرة عن اللي في بالك — شاليه، شقة، بيت، محل، مكتب، أرض، ولا عمارة؟ وبأي منطقة؟'
                : 'Give me a quick idea — chalet, apartment, house, shop, office, land, or building? And which area?');
        _appendReply(msg);
        return;
      }

      // Multi-area runs are valid even when the single `areaCode` slot is
      // empty: the agent emits an `areaCodes` list (chalet belt expansion or
      // explicit multi-area mention) and the search service does a Firestore
      // `whereIn` over it. Only block when BOTH are missing — otherwise we'd
      // ask "أي منطقة؟" right after the customer named three of them.
      final hasMultiAreaInFilters =
          _currentFilters['areaCodes'] is List &&
          (_currentFilters['areaCodes'] as List).length >= 2;
      final hasSingleAreaInFilters =
          _currentFilters['areaCode'] != null &&
          _currentFilters['areaCode'].toString().trim().isNotEmpty;
      if (!hasMultiAreaInFilters && !hasSingleAreaInFilters) {
        _appendReply(_isAr
            ? 'قل لي المنطقة (مثل القادسية، السالمية، خيران…) وخلني أشيك لك على المتاح 👀'
            : 'Tell me the area (e.g. Qadisiya, Salmiya, Khairan…) and I\'ll check what\'s available for you.');
        return;
      }

      final searchService = ConversationalSearchService();
      final userBudgetForQuery = _currentFilters['budget'] is num
          ? (_currentFilters['budget'] as num).toDouble()
          : (_currentFilters['budget'] != null ? double.tryParse(_currentFilters['budget'].toString()) : null);
      final limitPerBranch =
          (userBudgetForQuery != null && userBudgetForQuery > 0) ? 75 : 50;
      var docs = await searchService.fetchMarketplaceMergedFromMap(
        _currentFilters,
        limitPerCategory: limitPerBranch,
      );
      docs = docs
          .where((d) =>
              searchService.documentMatchesConversationFilters(d.data(), _currentFilters))
          .where((d) => _listingVisibleForAssistantSearch(d.data()))
          .toList();
      const maxDocsAfterFilter = 50;
      if (docs.length > maxDocsAfterFilter) {
        docs = docs.sublist(0, maxDocsAfterFilter);
      }
      if (userBudgetForQuery != null && userBudgetForQuery > 0) {
        docs = docs
            .where((d) {
              final p = d.data()['price'];
              final price = p is num ? p.toDouble() : (p != null ? double.tryParse(p.toString()) : null);
              return price != null && price <= userBudgetForQuery;
            })
            .take(30)
            .toList();
      }
      if (!mounted) return;
      setState(() {
        _lastResults = List.from(docs);
      });

      try {
        final interestUser = FirebaseAuth.instance.currentUser;
        if (interestUser != null && _currentFilters.isNotEmpty) {
          await UserInterestService().saveInterest(
            userId: interestUser.uid,
            filters: _currentFilters,
          );
        }
      } catch (_) {
        // ignore interest tracking errors; do not block chat response
      }

      final areaCode = _currentFilters['areaCode']?.toString().trim() ?? '';
      final userBudget = _currentFilters['budget'] is num
          ? (_currentFilters['budget'] as num).toDouble()
          : (_currentFilters['budget'] != null ? double.tryParse(_currentFilters['budget'].toString()) : null);

      var isNearbyFallback = false;
      var requestedAreaLabel = '';

      if (_lastResults.isEmpty) {
        final nearbyCodes = areaCode.isNotEmpty ? _nearbyAreaCodes[areaCode] : null;
        if (nearbyCodes != null && nearbyCodes.isNotEmpty) {
          var nearbyDocs = await searchService.fetchNearbyMarketplaceMergedFromMap(
            _currentFilters,
            nearbyCodes,
          );
          nearbyDocs = nearbyDocs
              .where((d) =>
                  searchService.documentMatchesConversationFilters(d.data(), _currentFilters))
              .where((d) => _listingVisibleForAssistantSearch(d.data()))
              .toList();
          if (nearbyDocs.isNotEmpty && mounted) {
            setState(() {
              _lastResults = List.from(nearbyDocs);
            });
            isNearbyFallback = true;
            requestedAreaLabel = _areaUiLabel(areaCode);
          }
        }
      }

      final userAskedForMore = _userAskedForMoreOptions(text);

      String reply;
      List<Map<String, dynamic>>? replyResults;
      var top3List = <Map<String, dynamic>>[];
      if (_lastResults.isEmpty) {
        final nearbyCodesForSimilar = areaCode.isNotEmpty ? _nearbyAreaCodes[areaCode] : null;
        // Phase 1 generalization: fire the similar-recommendations fallback
        // whenever we have an area to widen AROUND, even if the user never
        // declared a property type. The backend now tolerates empty
        // `propertyType` and returns nearby listings regardless of type.
        if (areaCode.isNotEmpty &&
            nearbyCodesForSimilar != null &&
            nearbyCodesForSimilar.isNotEmpty) {
          try {
            final similarResult = await aiBrain.findSimilarRecommendations(
              requestedAreaCode: areaCode,
              propertyType:
                  _currentFilters['type']?.toString().trim() ?? '',
              nearbyAreaCodes: nearbyCodesForSimilar,
              userBudget: userBudget,
            );
            final similarReply = similarResult['reply']?.toString() ?? '';
            final recs = similarResult['recommendations'] as List<dynamic>?;
            if (similarReply.isNotEmpty && recs != null && recs.isNotEmpty) {
              reply = similarReply;
              replyResults = recs.take(3).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            } else {
              reply = _isAr ? _assistantNoResultsAr : _assistantNoResultsEn;
            }
          } catch (e, st) {
            debugPrint('[Assistant] findSimilarRecommendations failed: $e');
            if (kDebugMode) debugPrint('$st');
            reply = _isAr ? _assistantNoResultsAr : _assistantNoResultsEn;
          }
        } else {
          reply = _isAr ? _assistantNoResultsAr : _assistantNoResultsEn;
        }
      } else {
        final propsForRank = _buildPropsForRank(_lastResults);
        final nearbyCodesForRank = isNearbyFallback
            ? (areaCode.isNotEmpty ? (_nearbyAreaCodes[areaCode] ?? const <String>[]) : const <String>[])
            : const <String>[];
        final rc = await aiBrain.rankAndComposeMarketingReply(
          properties: propsForRank,
          requestedAreaCode: areaCode,
          nearbyAreaCodes: nearbyCodesForRank,
          userBudget: userBudget,
          isAr: _isAr,
          userAskedForMore: userAskedForMore,
          isNearbyFallback: isNearbyFallback,
          requestedAreaLabel: requestedAreaLabel,
          rawMessage: text,
        );
        top3List = rc.top3;
        reply = rc.reply.trim();
        if (top3List.isNotEmpty && reply.isEmpty) {
          reply = _isAr
              ? 'أبشر، لقيت لك كم خيار مرتّب أدناه 👇 قل لي إذا تبي أضيّق أكثر أو أغيّر البحث.'
              : 'Here are a few solid options below 👇 tell me if you want me to narrow down or adjust the search.';
        }
        if (top3List.isNotEmpty && mounted) {
          final idList = top3List.map((e) => e['id'] as String?).whereType<String>().toList();
          final docById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
            for (final d in _lastResults) d.id: d
          };
          final orderedDocs = idList.map((id) => docById[id]).whereType<QueryDocumentSnapshot<Map<String, dynamic>>>().toList();
          if (orderedDocs.isNotEmpty) {
            setState(() {
              _lastResults = orderedDocs;
            });
          }
        }
        replyResults = _enrichResultsWithFullDocs(
          top3List.take(3).map((e) => Map<String, dynamic>.from(e)).toList(),
          _lastResults,
        );
      }
      final areaName = areaCode.isNotEmpty ? _areaUiLabel(areaCode) : null;
      final propertyType = _currentFilters['type']?.toString().trim();
      final serviceType = _currentFilters['serviceType']?.toString().trim();
      final staticTextChips = _buildSmartSuggestions(
        area: areaName,
        areaCodes: _activeAreaCodesFromFilters(),
        propertyType: propertyType?.isNotEmpty == true ? propertyType : null,
        serviceType: serviceType?.isNotEmpty == true ? serviceType : null,
        isAr: _isAr,
      ).map((s) => SuggestionChip.text(s)).toList();
      var finalChips = <SuggestionChip>[...staticTextChips];

      final isNoResultsNotifyFallback =
          top3List.isEmpty && (replyResults == null || replyResults.isEmpty);
      _awaitingNotifyConsent = isNoResultsNotifyFallback;

      // Smart Suggestions Engine. When the assistant produced a thin result
      // set (`< _weakResultThreshold`), probe the Cloud Function for concrete
      // alternatives (date shift / budget bump / nearby areas). The engine is
      // deterministic and uses the actual booking + blocked_dates data, so
      // its suggestions are guaranteed actionable rather than guesswork.
      // Resolve the TRUE count of results that will actually render under this
      // reply. We must check BOTH `replyResults` (the cards we'll send into
      // `_appendReply`) and `top3List` (the ranker's chosen triple) —
      // relying on just one side can misclassify a real result as empty and
      // trigger the "ما لقيت" copy while cards are visible below.
      final shownResultCount = (replyResults?.length ?? 0) > 0
          ? replyResults!.length
          : (top3List.isNotEmpty ? top3List.length : _lastResults.length);
      final hasAnyResults = shownResultCount > 0;
      final hasAnyFilterToTweak = areaCode.isNotEmpty ||
          (_currentFilters['budget'] != null) ||
          (_currentFilters['startDate'] != null);

      // TRUST GUARANTEE: if results exist, we NEVER surface the
      // "ما لقيت" / "I couldn't find" copy. If an earlier branch produced
      // that copy defensively, replace it with a positive framing BEFORE the
      // Smart Suggestions banner runs.
      if (hasAnyResults && _isNoResultsCopy(reply)) {
        reply = _isAr
            ? 'أبشر، لقيت لك كم خيار مرتّب 👇'
            : 'Here are a few solid options lined up for you 👇';
      }

      if (shownResultCount < _weakResultThreshold && hasAnyFilterToTweak) {
        final smart = await _fetchSmartSuggestions(
          baseFilters: _currentFilters,
          areaCode: areaCode,
          originalResultCount: shownResultCount,
        );
        if (smart != null) {
          final banner = _isAr
              ? (smart['banner_ar']?.toString().trim() ?? '')
              : (smart['banner_en']?.toString().trim() ?? '');
          // CRITICAL: The Smart Suggestions banner is intentionally framed as
          // a soft failure ("هالتواريخ محجوزة", "ما لقيت بميزانيتك"...).
          // That framing is ONLY valid when there are zero results shown.
          // If even one result is rendered, prepending the banner produces a
          // self-contradicting message ("I didn't find anything — here are 2
          // properties"). So we only use the banner when results are empty.
          if (banner.isNotEmpty && !hasAnyResults) {
            reply = reply.isEmpty ? banner : '$banner\n\n$reply';
          }
          final directChips = _extractDirectApplyChips(smart, _isAr);
          if (directChips.isNotEmpty) {
            // Smart chips (date/budget/area) take priority over the static
            // template chips; keep the top static chip as a gentle backup.
            finalChips = [
              ...directChips,
              ...staticTextChips.take(1),
            ].take(3).toList();
          }
        }
      }

      // Final safety net — if we somehow still ended up with a "no results"
      // copy while results exist, rewrite it now. Defense in depth: any
      // future branch that sets `reply = _assistantNoResultsAr` without
      // checking the result set won't break user trust.
      if (hasAnyResults && _isNoResultsCopy(reply)) {
        reply = _isAr
            ? 'أبشر، لقيت لك كم خيار مرتّب 👇'
            : 'Here are a few solid options lined up for you 👇';
      }

      _appendReply(
        reply,
        results: replyResults,
        suggestions: finalChips.isNotEmpty ? finalChips : null,
      );
    } catch (e, st) {
      _awaitingNotifyConsent = false;
      if (e is FirebaseFunctionsException) {
        debugPrint(
          '[Assistant] _sendMessage FirebaseFunctionsException code=${e.code} message=${e.message}',
        );
      } else if (e is TimeoutException) {
        debugPrint('[Assistant] _sendMessage TimeoutException');
      } else {
        debugPrint('[Assistant] _sendMessage error: $e');
      }
      if (kDebugMode) {
        debugPrint('[Assistant] stack: $st');
      }

      final isOfflineStyle = e is SocketException ||
          e is HandshakeException ||
          (e is OSError && _isNetworkOsError(e.errorCode));

      final String message;
      if (isOfflineStyle) {
        message = _isAr
            ? 'ما في اتصال بالإنترنت أو الشبكة ضعيفة. تحقق من الاتصال ثم جرّب مرة ثانية، أو استخدم البحث العادي (X).'
            : 'No internet or a weak connection. Reconnect and try again, or use traditional search (X).';
      } else {
        message = AiBrainService.userFacingErrorMessage(e, isArabic: _isAr);
      }

      _appendReply(message);
    }
  }

  /// True when [reply] is a "no results" framing (either the static template
  /// or any reply that leads with the characteristic Arabic/English fail
  /// phrases). Used to sanitize replies before composition — if we have
  /// results to show, we must never lead with "couldn't find".
  static bool _isNoResultsCopy(String reply) {
    if (reply.isEmpty) return false;
    if (reply == _assistantNoResultsAr) return true;
    if (reply == _assistantNoResultsEn) return true;
    final head = reply.trimLeft();
    // Match the exact opening phrases used in the no-results templates and
    // the Smart Suggestions failure banners. Kept narrow on purpose — we do
    // NOT want a ranker reply that happens to contain "لقيت" to match.
    const arFailLeads = <String>[
      'ما لقيت', // generic
      'هالتواريخ محجوزة',
      'ما لقيت مناسب',
      'المنطقة فاضية',
      'بنفس المواصفات بالضبط ما',
      'بميزانيتك الحالية',
      'بهالتواريخ أغلب',
      'بهالتواريخ السوق',
      'المنطقة مستهلكة',
    ];
    const enFailLeads = <String>[
      "i couldn't find",
      "i could not find",
      'nothing matched',
      'nothing matches',
      'nothing in that area',
      'nothing in this area',
      'those dates are booked',
      'those dates are fully booked',
      'most chalets are booked',
      'that area is thin',
      'that window is crowded',
      'your current budget is tight',
    ];
    for (final lead in arFailLeads) {
      if (head.startsWith(lead)) return true;
    }
    final headLower = head.toLowerCase();
    for (final lead in enFailLeads) {
      if (headLower.startsWith(lead)) return true;
    }
    return false;
  }

  /// True for common OS error codes that mean network unreachable / no route.
  static bool _isNetworkOsError(int? code) {
    if (code == null) return false;
    // 50 = Network is down (macOS/iOS), 51 = Network unreachable, 61 = Connection refused, etc.
    return const [50, 51, 61, 64, 65].contains(code);
  }

  /// User confirmed they want notify/interest after a no-results fallback (short replies only).
  static bool _isAffirmativeNotifyConsent(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return false;
    final lower = s.toLowerCase();
    if (RegExp(r'^(ok|okay|yes|y)([.!…]*)$', caseSensitive: false).hasMatch(lower)) {
      return true;
    }
    final inner = s
        .replaceAll(RegExp(r'^[\s.!؟،,…]+|[\s.!؟،,…]+$'), '')
        .trim();
    const ar = <String>{
      'نعم',
      'اي',
      'أي',
      'ايه',
      'أيه',
      'تمام',
      'موافق',
      'اوكي',
      'أوكي',
      'ايوه',
      'أيوه',
      'ايوة',
      'أيوة',
    };
    return ar.contains(inner) || ar.contains(s);
  }

  /// Pull the active multi-area selection out of `_currentFilters`. Returns
  /// `[]` when the customer is in single-area mode (or hasn't picked an area
  /// yet) — callers treat empty as "no multi-area, behave like before".
  List<String> _activeAreaCodesFromFilters() {
    final raw = _currentFilters['areaCodes'];
    if (raw is! List) return const [];
    final cleaned = raw
        .map((v) => v?.toString().trim().toLowerCase() ?? '')
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    return cleaned.length >= 2 ? cleaned : const [];
  }

  /// Build contextual suggestion buttons based on current search filters.
  ///
  /// Persona rules (kept aligned with `agent_brain.ts` ANALYZE_SYSTEM):
  ///   • DEFAULT SORT IS QUALITY, NOT PRICE. We never auto-offer
  ///     "وريني الأرخص" / "Show the cheapest" — that chip caused the bot to
  ///     drag customers down-market on every chalet turn. The الأرخص modifier
  ///     still works when the customer types it themselves; the chat brain
  ///     parses it via [detectSearchModifier].
  ///   • CHALETS GET CONSULTATIVE CHIPS. After a chalet result lands, real
  ///     brokers ask "صف أول على البحر؟" / "حق عوايل ولا شباب؟" — those are
  ///     the chips here, not generic "show me beachfront".
  ///   • MULTI-AREA SUPPORT. When the customer is browsing 2+ chalet-belt
  ///     areas in one breath, we surface a "بس بـ {area}" chip per area so
  ///     they can narrow with one tap. Each chip carries the canonical
  ///     `areaCode` slug verbatim — the chat brain's resolver already maps it
  ///     back to a single-area search on click.
  List<String> _buildSmartSuggestions({
    String? area,
    List<String> areaCodes = const [],
    String? propertyType,
    String? serviceType,
    bool isAr = true,
  }) {
    final suggestions = <String>[];
    final isChalet = propertyType == 'chalet';
    final cleanedAreaCodes = areaCodes
        .map((c) => c.trim().toLowerCase())
        .where((c) => c.isNotEmpty)
        .toList();
    final isMultiArea = cleanedAreaCodes.length >= 2;

    if (isAr) {
      if (isChalet) {
        suggestions.add('صف أول على البحر');
        suggestions.add('حق عوايل');
      }
      if (isMultiArea) {
        for (final code in cleanedAreaCodes.take(3)) {
          final label = _areaUiLabel(code);
          if (label.isNotEmpty) suggestions.add('بس بـ $label');
        }
      } else if (area != null && area.isNotEmpty) {
        suggestions.add('خيارات قريبة بنفس المميزات');
      }
      if (propertyType == 'house') {
        suggestions.add('شقق بنفس المنطقة');
      }
      if (propertyType == 'apartment') {
        suggestions.add('بيوت بنفس المنطقة');
      }
      if (serviceType == 'sale') {
        suggestions.add('عندك خيارات إيجار بنفس المنطقة');
      }
    } else {
      if (isChalet) {
        suggestions.add('Beachfront row only');
        suggestions.add('Family-friendly');
      }
      if (isMultiArea) {
        for (final code in cleanedAreaCodes.take(3)) {
          final label = _areaUiLabel(code);
          if (label.isNotEmpty) suggestions.add('Just in $label');
        }
      } else if (area != null && area.isNotEmpty) {
        suggestions.add('Nearby options with the same perks');
      }
      if (propertyType == 'house') {
        suggestions.add('Apartments in the same area');
      }
      if (propertyType == 'apartment') {
        suggestions.add('Houses in the same area');
      }
      if (serviceType == 'sale') {
        suggestions.add('Rentals in the same area');
      }
    }
    return suggestions.take(3).toList();
  }

  /// Calls the Smart Suggestions engine for the current conversation turn.
  ///
  /// Only runs when we actually have a filter dimension worth tweaking
  /// (dates, budget, or area). Returns the raw server payload on success
  /// (`{ triggered, failureReason, alternatives[], banner_ar, banner_en }`)
  /// or `null` on any failure — the caller is expected to silently fall back
  /// to the legacy static chips in that case.
  ///
  /// We deliberately re-fetch the candidate pool *without* the availability
  /// gate (`applyAvailabilityGate: false`). That gives the server the full
  /// set of discoverable chalets so the date-shift probe can measure how
  /// many become free one / two / three days later against real bookings —
  /// the "use real data" requirement.
  Future<Map<String, dynamic>?> _fetchSmartSuggestions({
    required Map<String, dynamic> baseFilters,
    required String areaCode,
    required int originalResultCount,
  }) async {
    try {
      final svc = (baseFilters['serviceType']?.toString().trim().toLowerCase() ?? '');
      final type = (baseFilters['type']?.toString().trim().toLowerCase() ?? '');
      final rentalType = (baseFilters['rentalType']?.toString().trim().toLowerCase() ?? '');
      final dateBookable = svc == 'rent' && (type == 'chalet' || rentalType == 'daily');
      final hasDates = baseFilters['startDate'] != null && baseFilters['endDate'] != null;

      List<String> candidateIds = const <String>[];
      if (dateBookable && hasDates) {
        // Pull the raw (pre-gate) pool from the SAME filter map the chat just
        // used. `applyAvailabilityGate: false` is the critical bit: we want
        // the server to measure availability across shifted windows, not
        // re-measure the original window we just failed on.
        try {
          final preGate = await ConversationalSearchService()
              .fetchMarketplaceMergedFromMap(
            baseFilters,
            limitPerCategory: 60,
            applyAvailabilityGate: false,
          );
          candidateIds = preGate.map((d) => d.id).toList();
        } catch (_) {
          candidateIds = const <String>[];
        }
      }

      final neighbors = areaCode.isNotEmpty
          ? (_nearbyAreaCodes[areaCode] ?? const <String>[])
          : const <String>[];

      final payload = <String, dynamic>{
        ...baseFilters,
        // Server expects `propertyType`; the chat uses `type` internally.
        if (baseFilters['type'] != null) 'propertyType': baseFilters['type'],
        // Rename `budget` → `maxPrice` to match the smart_suggestions contract.
        if (baseFilters['budget'] != null) 'maxPrice': baseFilters['budget'],
      };

      return await AiBrainService().generateChatSmartSuggestions(
        filters: payload,
        originalResultCount: originalResultCount,
        candidatePropertyIds: candidateIds,
        nearbyAreaCodes: neighbors,
      );
    } catch (e) {
      debugPrint('[Assistant] smart suggestions failed: $e');
      return null;
    }
  }

  /// Converts the Smart Suggestions response into direct-apply
  /// [SuggestionChip]s. Each chip carries the server-returned filter patch
  /// (canonical keys: `propertyType`, `maxPrice`, `areaCode`, `startDate`,
  /// `endDate`, `nights`, etc.) so the UI can apply it in-place without
  /// re-parsing a text message.
  List<SuggestionChip> _extractDirectApplyChips(
    Map<String, dynamic> smart,
    bool isAr,
  ) {
    final alts = smart['alternatives'];
    if (alts is! List) return const <SuggestionChip>[];
    final out = <SuggestionChip>[];
    for (final a in alts) {
      if (a is! Map) continue;
      final headline =
          (isAr ? a['headline_ar'] : a['headline_en'])?.toString().trim() ?? '';
      if (headline.isEmpty) continue;
      final rawFilters = a['filters'];
      Map<String, dynamic>? filters;
      if (rawFilters is Map) {
        filters = Map<String, dynamic>.from(rawFilters);
      }
      final rawKind = a['kind']?.toString().trim();
      final kind = (rawKind != null && rawKind.isNotEmpty) ? rawKind : null;
      out.add(SuggestionChip(headline, filters: filters, kind: kind));
    }
    return out;
  }

  /// Handles the two chip flavors:
  ///   - **Direct-apply**: merges the filter patch into `_currentFilters`,
  ///     re-runs the Firestore search, and appends a fresh assistant message
  ///     *without* sending a user message or re-invoking the LLM. This is the
  ///     core of the "real-time assistant" UX upgrade.
  ///   - **Text-only** (legacy / static chips): falls back to the old
  ///     `_sendMessage(headline)` path so existing refinement flows keep
  ///     working without code duplication.
  Future<void> _applySuggestionChip(SuggestionChip chip) async {
    // Analytics (every tap, before any early-return so we never lose a click).
    final previousResultCount = _lastResults.length;
    final clickStopwatch = Stopwatch()..start();
    try {
      ChatAnalyticsService().logEvent(
        ChatAnalyticsEvents.suggestionClick,
        <String, dynamic>{
          'headline': chip.headline,
          'type': chip.kind,
          'directApply': chip.isDirectApply,
          'previousResultCount': previousResultCount,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        },
      );
    } catch (_) {/* silent */}

    if (!chip.isDirectApply) {
      await _sendMessage(chip.headline);
      return;
    }
    if (_isLoading) return;

    // Merge chip.filters into the in-memory filter map. Canonical server
    // keys (`propertyType`, `maxPrice`) map to the chat's internal keys
    // (`type`, `budget`); all other keys pass through unchanged. The
    // translation is defensive: unknown keys are ignored so a future
    // server-side strategy can't silently corrupt `_currentFilters`.
    _currentFilters = _mergeChipFiltersIntoCurrent(_currentFilters, chip.filters!);

    // Guarantee the latest filter snapshot is what the search will use.
    setState(() {
      _isLoading = true;
      _assistantTyping = true;
    });
    _scrollToBottom();

    try {
      final searchService = ConversationalSearchService();
      final docs = await searchService.fetchMarketplaceMergedFromMap(
        _currentFilters,
        limitPerCategory: 60,
      );
      if (!mounted) return;
      setState(() {
        _lastResults = List.from(docs);
      });

      final areaCode = _currentFilters['areaCode']?.toString().trim() ?? '';
      final userBudget = _currentFilters['budget'] is num
          ? (_currentFilters['budget'] as num).toDouble()
          : (_currentFilters['budget'] != null
              ? double.tryParse(_currentFilters['budget'].toString())
              : null);

      String reply;
      List<Map<String, dynamic>>? replyResults;
      var top3List = <Map<String, dynamic>>[];

      if (_lastResults.isEmpty) {
        // No matches after direct-apply. This is rare (the server validated
        // the alternative against real availability data) but possible if
        // another user booked the last chalet between suggestion and click.
        reply = _isAr ? _assistantNoResultsAr : _assistantNoResultsEn;
      } else {
        final propsForRank = _buildPropsForRank(_lastResults);
        try {
          final rc = await AiBrainService().rankAndComposeMarketingReply(
            properties: propsForRank,
            requestedAreaCode: areaCode,
            nearbyAreaCodes: const [],
            userBudget: userBudget,
            isAr: _isAr,
            userAskedForMore: false,
            isNearbyFallback: false,
            requestedAreaLabel: '',
            rawMessage: chip.headline,
          );
          top3List = rc.top3;
          reply = rc.reply.trim();
          replyResults = _enrichResultsWithFullDocs(
            top3List.take(3).map((e) => Map<String, dynamic>.from(e)).toList(),
            _lastResults,
          );
        } catch (e) {
          debugPrint('[Assistant] direct-apply rank/compose failed: $e');
          // Degrade gracefully to an unranked listing of the first 3 docs so
          // the user still sees results even if the rank/compose Cloud
          // Function fails transiently.
          top3List = _lastResults
              .take(3)
              .map((d) => <String, dynamic>{...d.data(), 'id': d.id})
              .toList();
          replyResults = top3List;
          reply = '';
        }
      }

      // Trust guarantee: even though `_lastResults.isEmpty` is handled above,
      // the ranker can still return a reply that leads with a "couldn't find"
      // phrase (LLM hallucination). If results exist, strip any such reply
      // so the user doesn't see "Here are the updated results 👇\n\nI didn't
      // find anything".
      if (_lastResults.isNotEmpty && _isNoResultsCopy(reply)) {
        reply = '';
      }

      final intro = _isAr
          ? (_lastResults.isEmpty
              ? ''
              : 'أبشر، هذي النتائج بعد التعديل 👇')
          : (_lastResults.isEmpty
              ? ''
              : 'Done — here are the options after the tweak 👇');
      final String finalReply;
      if (_lastResults.isEmpty) {
        finalReply = reply;
      } else {
        finalReply = reply.isEmpty ? intro : '$intro\n\n$reply';
      }

      // Persist interest on a successful direct-apply (the user actively
      // committed to the refined filters by tapping).
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null && _currentFilters.isNotEmpty) {
          await UserInterestService().saveInterest(
            userId: user.uid,
            filters: Map<String, dynamic>.from(_currentFilters),
          );
        }
      } catch (_) {
        // Interest tracking is best-effort; never block the reply.
      }

      // Analytics: close the loop on the direct-apply click with the
      // resulting count + latency. `success = resultCount > 0` matches the
      // spec's definition. Note: _lastResults reflects the post-apply set.
      try {
        clickStopwatch.stop();
        ChatAnalyticsService().logEvent(
          ChatAnalyticsEvents.suggestionResult,
          <String, dynamic>{
            'resultCount': _lastResults.length,
            'success': _lastResults.isNotEmpty,
            'filtersApplied': <String, dynamic>{
              if (_currentFilters['areaCode'] != null)
                'areaCode': _currentFilters['areaCode'],
              if (_currentFilters['type'] != null)
                'propertyType': _currentFilters['type'],
              if (_currentFilters['serviceType'] != null)
                'serviceType': _currentFilters['serviceType'],
              if (_currentFilters['budget'] != null)
                'maxPrice': _currentFilters['budget'],
              if (_currentFilters['startDate'] != null)
                'startDate': _currentFilters['startDate'],
              if (_currentFilters['endDate'] != null)
                'endDate': _currentFilters['endDate'],
              if (_currentFilters['nights'] != null)
                'nights': _currentFilters['nights'],
            },
            'chipType': chip.kind,
            'responseTimeMs': clickStopwatch.elapsedMilliseconds,
          },
        );
      } catch (_) {/* silent */}

      _appendReply(finalReply, results: replyResults);
    } catch (e, st) {
      debugPrint('[Assistant] _applySuggestionChip error: $e');
      if (kDebugMode) debugPrint('$st');
      try {
        clickStopwatch.stop();
        ChatAnalyticsService().logEvent(
          ChatAnalyticsEvents.suggestionResult,
          <String, dynamic>{
            'resultCount': 0,
            'success': false,
            'error': e.toString(),
            'chipType': chip.kind,
            'responseTimeMs': clickStopwatch.elapsedMilliseconds,
          },
        );
      } catch (_) {/* silent */}
      _appendReply(AiBrainService.userFacingErrorMessage(e, isArabic: _isAr));
    }
  }

  /// Defensive merge. Accepts the server's canonical keys (matches
  /// `SuggestionFilters` in `functions/src/smart_suggestions.ts`) and maps
  /// them to the chat's internal filter-map keys. Only the whitelist below
  /// is copied — unknown keys are dropped on the floor so a future server
  /// strategy change cannot inject arbitrary fields into the client state.
  static Map<String, dynamic> _mergeChipFiltersIntoCurrent(
    Map<String, dynamic> current,
    Map<String, dynamic> patch,
  ) {
    final merged = Map<String, dynamic>.from(current);
    void copy(String source, String dest) {
      if (patch.containsKey(source) && patch[source] != null) {
        merged[dest] = patch[source];
      }
    }

    copy('areaCode', 'areaCode');
    copy('governorateCode', 'governorateCode');
    copy('serviceType', 'serviceType');
    copy('rentalType', 'rentalType');
    copy('bedrooms', 'bedrooms');
    copy('startDate', 'startDate');
    copy('endDate', 'endDate');
    copy('nights', 'nights');
    // Key translations (server ↔ client naming):
    copy('propertyType', 'type');
    copy('maxPrice', 'budget');

    return merged;
  }

  void _appendReply(
    String text, {
    List<Map<String, dynamic>>? results,
    List<SuggestionChip>? suggestions,
  }) {
    if (!mounted) return;
    final list = results != null && results.isNotEmpty
        ? results.take(3).map((e) => Map<String, dynamic>.from(e)).toList()
        : null;
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
        results: list,
        suggestions: suggestions,
      ));
      _isLoading = false;
      _assistantTyping = false;
    });
    _scrollToBottom();

    // Analytics: record the impression right when the chips hit the screen.
    // Only log when we're actually showing direct-apply chips — static text
    // chips are low-signal and would drown out the suggestion funnel metrics.
    if (suggestions != null && suggestions.isNotEmpty) {
      final directApply =
          suggestions.where((c) => c.isDirectApply).toList(growable: false);
      if (directApply.isNotEmpty) {
        _logSuggestionImpression(directApply);
      }
    }
  }

  /// Fires `suggestion_impression` with the types + current filter context.
  /// Fire-and-forget; never throws.
  void _logSuggestionImpression(List<SuggestionChip> chips) {
    try {
      final types = <String>[
        for (final c in chips)
          if (c.kind != null && c.kind!.isNotEmpty) c.kind!
      ];
      final filters = _currentFilters;
      ChatAnalyticsService().logEvent(
        ChatAnalyticsEvents.suggestionImpression,
        <String, dynamic>{
          'suggestionCount': chips.length,
          'types': types,
          'filters': <String, dynamic>{
            if (filters['areaCode'] != null) 'areaCode': filters['areaCode'],
            if (filters['type'] != null) 'propertyType': filters['type'],
            if (filters['serviceType'] != null)
              'serviceType': filters['serviceType'],
          },
          'hasDateRange': filters['startDate'] != null &&
              filters['endDate'] != null,
        },
      );
    } catch (_) {/* silent */}
  }

  /// Compact memory of the last 3 listings shown (order = rank 1..3) for analyze / reference resolution.
  List<Map<String, dynamic>> _top3MemoryForAnalyze() {
    if (_lastResults.isEmpty) return [];
    final n = _lastResults.length >= 3 ? 3 : _lastResults.length;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < n; i++) {
      final doc = _lastResults[i];
      final d = doc.data();
      final price = d['price'];
      num? p;
      if (price is num) {
        p = price;
      } else if (price != null) {
        p = num.tryParse(price.toString());
      }
      final area = '${d['areaAr'] ?? d['areaEn'] ?? ''}'.trim();
      final ptype = '${d['type'] ?? ''}'.trim();
      out.add(<String, dynamic>{
        'propertyId': doc.id,
        'price': p,
        'area': area,
        'propertyType': ptype,
        'rank': i + 1,
      });
    }
    return out;
  }

  List<Map<String, String>> _last8Messages() {
    final list = <Map<String, String>>[];
    final start = _messages.length > 8 ? _messages.length - 8 : 0;
    for (var i = start; i < _messages.length; i++) {
      final m = _messages[i];
      list.add({
        'role': m.isUser ? 'user' : 'assistant',
        'content': m.text,
      });
    }
    return list;
  }

  /// Merges ranked results (top3 from backend) with full Firestore doc data so cards get images/coverUrl.
  List<Map<String, dynamic>> _enrichResultsWithFullDocs(
    List<Map<String, dynamic>> ranked,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> fullDocs,
  ) {
    if (fullDocs.isEmpty) return ranked;
    final docById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
      for (final d in fullDocs) d.id: d
    };
    return ranked.map((e) {
      final id = e['id']?.toString();
      final doc = id != null ? docById[id] : null;
      if (doc == null) return Map<String, dynamic>.from(e);
      final full = Map<String, dynamic>.from(doc.data());
      full['id'] = doc.id;
      if (e['labels'] != null) full['labels'] = e['labels'];
      return full;
    }).toList();
  }

  /// Builds property maps for ranking (id, areaCode, areaAr, areaEn, type, price, size, createdAt, featuredUntil).
  /// Sends timestamps as milliseconds so the backend can score recency and featured.
  List<Map<String, dynamic>> _buildPropsForRank(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    return docs.map((doc) {
      final d = doc.data();
      final createdAt = d['createdAt'];
      final featuredUntil = d['featuredUntil'];
      return <String, dynamic>{
        'id': doc.id,
        'areaCode': d['areaCode'],
        'areaAr': d['areaAr'],
        'areaEn': d['areaEn'],
        'type': d['type'],
        'price': d['price'],
        'size': d['size'],
        'createdAt': createdAt is Timestamp ? createdAt.millisecondsSinceEpoch : createdAt,
        'featuredUntil': featuredUntil is Timestamp ? featuredUntil.millisecondsSinceEpoch : featuredUntil,
        'features': <String, bool>{
          'hasElevator': (d['hasElevator'] ?? false) == true,
          'hasCentralAC': (d['hasCentralAC'] ?? false) == true,
          'hasSplitAC': (d['hasSplitAC'] ?? false) == true,
          'hasMaidRoom': (d['hasMaidRoom'] ?? false) == true,
          'hasDriverRoom': (d['hasDriverRoom'] ?? false) == true,
          'hasLaundryRoom': (d['hasLaundryRoom'] ?? false) == true,
          'hasGarden': (d['hasGarden'] ?? false) == true,
          'hasPoolIndoor': (d['hasPoolIndoor'] ?? false) == true,
          'hasPoolOutdoor': (d['hasPoolOutdoor'] ?? false) == true,
          'isBeachfront': (d['isBeachfront'] ?? false) == true,
        },
      };
    }).toList();
  }

  /// True if the user message suggests they want more/different options (e.g. "عندك أكثر؟", "غيره؟").
  bool _userAskedForMoreOptions(String message) {
    final lower = message.trim().toLowerCase();
    // Listing picks (الثاني، الأرخص…) — not "show me more options"
    if (RegExp(r'الثاني|الثالث|الأول|الاول|الأرخص|الارخص|الأغلى|الاغلى|اللي قبل|الي قبل|السابق|الأخير|الاخير')
        .hasMatch(lower)) {
      return false;
    }
    const arPatterns = ['أكثر', 'اغير', 'غيره', 'ثاني', 'ثانية', 'غير', 'خيارات', 'بديل', 'بدائل'];
    const enPatterns = ['more', 'another', 'other', 'different', 'alternatives', 'options', 'else'];
    final hasAr = arPatterns.any((p) => lower.contains(p));
    final hasEn = enPatterns.any((p) => lower.contains(p));
    return hasAr || hasEn;
  }

  void _closeToTraditionalSearch() {
    // Must update GoRouter location — replacing only the `/` page via
    // [Navigator.pushReplacement] left the URI at `/`, so after opening a
    // listing with [context.pushPropertyDetails] and popping, GoRouter
    // rebuilt [AssistantPage]. `/home` keeps back navigation on the hub.
    context.go('/home');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);

    // ChatGPT-style: خلفية بيضاء بالكامل
    const Color surfaceWhite = Color(0xFFFFFFFF);
    const Color surfaceLightGrey = Color(0xFFF1F1F1);
    const Color textDark = Color(0xFF1A1A1A);
    const Color textSecondary = Color(0xFF6B6B6B);
    const Color accentPrimary = Color(0xFF101046);

    return Scaffold(
      backgroundColor: surfaceWhite,
      body: SafeArea(
        child: Column(
          children: [
            // هيدر بأسلوب ChatGPT: كبسولات رمادية فاتحة
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: surfaceLightGrey,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome, color: accentPrimary, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          isAr ? 'مساعدك العقاري' : 'AqarAi',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: textDark,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  const NotificationsInboxBellButton(isOnDarkBackground: false),
                  const SizedBox(width: 8),
                  Material(
                    color: surfaceLightGrey,
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      onTap: _closeToTraditionalSearch,
                      borderRadius: BorderRadius.circular(24),
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.close, color: textDark, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              isAr ? 'اضغط X للبحث التقليدي' : 'Tap X for traditional search',
              style: const TextStyle(color: textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 6),

            // منطقة الشات — خلفية بيضاء
            Expanded(
              child: Container(
                color: surfaceWhite,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: _messages.length + (_assistantTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _messages.length) {
                      return _buildTypingIndicator();
                    }
                    final msg = _messages[index];
                    return _buildMessageBubble(msg);
                  },
                ),
              ),
            ),

            // حقل الإدخال — رمادي فاتح مثل ChatGPT
            Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
              color: surfaceWhite,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onSubmitted: (_) => _sendMessage(),
                      style: const TextStyle(color: textDark, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: isAr ? 'اسأل أي شيء...' : 'Ask anything...',
                        hintStyle: const TextStyle(color: textSecondary, fontSize: 15),
                        filled: true,
                        fillColor: surfaceLightGrey,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Material(
                    color: accentPrimary,
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      onTap: _isLoading ? null : _sendMessage,
                      borderRadius: BorderRadius.circular(24),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Icon(
                          Icons.send_rounded,
                          color: _isLoading ? Colors.white38 : Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens listing details **on top of** this chat route via [Navigator.push], so
  /// popping returns here with [_messages] intact. Using [GoRouter.push] from chat
  /// breaks stacks opened with [Navigator.push] (e.g. Home → Assistant) and looks
  /// like an empty restart after closing details. Web keeps URL routing via
  /// [context.pushPropertyDetails].
  Future<void> _openPropertyDetailsFromChat({
    required String propertyId,
    String? captionTrackingId,
  }) async {
    final id = propertyId.trim();
    if (id.isEmpty || !mounted) return;

    if (kIsWeb) {
      if (!mounted) return;
      context.pushPropertyDetails(
        propertyId: id,
        leadSource: DealLeadSource.aiChat,
        captionTrackingId: captionTrackingId,
      );
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => BannedUserSessionGate(
          child: PropertyDetailsPage(
            propertyId: id,
            leadSource: DealLeadSource.aiChat,
            captionTrackingId: captionTrackingId,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.isUser;
    final assistantResults = msg.results != null && msg.results!.isNotEmpty
        ? msg.results!.take(3).toList()
        : <Map<String, dynamic>>[];

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(child: ChatBubble(message: msg.text, isUser: true)),
            const SizedBox(width: 8),
            _buildUserAvatar(),
          ],
        ),
      );
    }

    // AI message: left-aligned row with avatar, bubble (ChatBubble style), then cards/suggestions
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAssistantAvatar(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ChatBubble(message: msg.text, isUser: false),
                if (assistantResults.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...assistantResults.map((property) {
                    final id = property['id']?.toString() ?? '';
                    final labels = property['labels'];
                    final labelList = labels is List
                        ? (labels).map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList()
                        : null;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ListingCard(
                        id: id,
                        data: property,
                        labels: labelList?.isNotEmpty == true ? labelList : null,
                        onTap: id.isEmpty
                            ? null
                            : () {
                                unawaited(_openPropertyDetailsFromChat(propertyId: id));
                              },
                      ),
                    );
                  }),
                ],
                if (msg.suggestions != null && msg.suggestions!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: msg.suggestions!.map((chip) {
                        // Direct-apply chips (with a filters patch) get a
                        // slightly stronger visual weight so users see they
                        // are actionable filters, not just refinement
                        // prompts. Text chips fall back to the legacy
                        // "send as message" interaction.
                        final isDirect = chip.isDirectApply;
                        final bg = isDirect
                            ? const Color(0xFFE8EEFF)
                            : const Color(0xFFF1F1F1);
                        final border = isDirect
                            ? Border.all(color: const Color(0xFF3354D6), width: 1)
                            : null;
                        final textColor = isDirect
                            ? const Color(0xFF1E3AA8)
                            : const Color(0xFF1A1A1A);
                        return GestureDetector(
                          onTap: _isLoading
                              ? null
                              : () => _applySuggestionChip(chip),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(20),
                              border: border,
                            ),
                            child: Text(
                              chip.headline,
                              style: TextStyle(
                                fontSize: 14,
                                color: textColor,
                                fontWeight:
                                    isDirect ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// دائرة واحدة ناعمة (بخط واحد) ثم اللوقو بداخلها — بدون ClipOval مزدوج.
  static const double _avatarSize = 32;

  /// صورة Google/Apple من [User.photoURL]؛ بدون صورة: حرف من الاسم/البريد؛ دخول ضيف: لوقو التطبيق.
  Widget _buildUserAvatar() {
    final user = FirebaseAuth.instance.currentUser;
    final url = user?.photoURL?.trim();
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: _avatarSize,
          height: _avatarSize,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return SizedBox(
              width: _avatarSize,
              height: _avatarSize,
              child: const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) => _userAvatarFallback(user),
        ),
      );
    }
    return _userAvatarFallback(user);
  }

  static String _userInitial(User? user) {
    final d = user?.displayName?.trim();
    if (d != null && d.isNotEmpty) {
      return String.fromCharCode(d.runes.first);
    }
    final e = user?.email?.trim();
    if (e != null && e.isNotEmpty) {
      return e[0].toUpperCase();
    }
    return '?';
  }

  Widget _userAvatarFallback(User? user) {
    final anonymous = user?.isAnonymous == true;
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF101046),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: anonymous
          ? Padding(
              padding: const EdgeInsets.all(5),
              child: Image.asset(
                'assets/images/aqarai_chat_logo.png',
                fit: BoxFit.contain,
              ),
            )
          : Text(
              _userInitial(user),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }

  Widget _buildAssistantAvatar() {
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF101046),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Image.asset(
          'assets/images/aqarai_chat_logo.png',
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAssistantAvatar(),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F1F1),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(18),
              ),
            ),
            child: const _TypingDots(),
          ),
        ],
      ),
    );
  }
}

/// Three animated dots for "AI is typing" indicator.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value * 3; // 0..3 over one cycle
        double opacity(int i) {
          final x = (t - i) % 3;
          if (x < 0.4) return 0.3 + 0.7 * (x / 0.4);
          if (x < 0.8) return 1.0;
          return 1.0 - (x - 0.8) / 0.2 * 0.7;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(opacity(0)),
            const SizedBox(width: 4),
            _dot(opacity(1)),
            const SizedBox(width: 4),
            _dot(opacity(2)),
          ],
        );
      },
    );
  }

  Widget _dot(double opacity) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: Color.lerp(const Color(0xFFE0E0E0), const Color(0xFF1A1A1A), opacity.clamp(0.0, 1.0))!,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A quick-reply chip under an assistant message.
///
/// Two flavors:
///   - **Text chip** (legacy): `filters == null`. Tapping it sends [headline]
///     as a new user message — same behavior the chat has always had for the
///     static template chips ("Cheaper options in Qadisiya", "A bit bigger",
///     etc.).
///   - **Direct-apply chip** (new, via Smart Suggestions Engine): `filters`
///     is a non-empty filter patch using server-canonical keys
///     (`propertyType`, `maxPrice`, `serviceType`, `areaCode`, `startDate`,
///     `endDate`, `nights`, optionally `rentalType` / `governorateCode` /
///     `bedrooms`). Tapping merges the patch into `_currentFilters`, re-runs
///     the Firestore search, ranks, and appends a fresh assistant message —
///     **without** sending a user message or re-invoking `parseUserMessage`.
///     This is the "feels like a real-time assistant" path.
///
/// [filters] is stored as a plain `Map<String, dynamic>` (not a typed model)
/// so it survives a `setState` rebuild without custom serialization, and so
/// the map can be injected into `_currentFilters` which is already
/// `Map<String, dynamic>`.
class SuggestionChip {
  final String headline;
  final Map<String, dynamic>? filters;

  /// Server-side strategy that produced this chip, one of:
  ///   - `availability_shift`
  ///   - `budget_bump`
  ///   - `area_widen`
  ///
  /// `null` for legacy static/text chips. Used for analytics only — behavior
  /// is fully determined by [filters].
  final String? kind;

  const SuggestionChip(this.headline, {this.filters, this.kind});

  /// Shorthand for legacy text-only chips.
  const SuggestionChip.text(this.headline)
      : filters = null,
        kind = null;

  bool get isDirectApply => filters != null && filters!.isNotEmpty;
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  /// When non-null and non-empty, show up to 3 property cards under this (assistant) message.
  final List<Map<String, dynamic>>? results;
  /// Optional quick-reply chips shown under assistant messages.
  final List<SuggestionChip>? suggestions;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.results,
    this.suggestions,
  });
}
