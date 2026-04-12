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
import 'package:aqarai_app/home_page.dart';
import 'package:aqarai_app/services/ai_brain_service.dart';
import 'package:aqarai_app/services/conversational_search_service.dart';
import 'package:aqarai_app/services/user_interest_service.dart';
import 'package:aqarai_app/services/notification_service.dart';
import 'package:aqarai_app/services/user_activity_service.dart';
import 'package:aqarai_app/widgets/chat_bubble.dart';
import 'package:aqarai_app/widgets/listing_card.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';
import 'package:aqarai_app/widgets/notifications_inbox_bell_button.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/utils/property_area_display.dart';

/// إعلان يُعرض في نتائج المساعد (معتمد وظاهر للعميل).
bool _listingVisibleForAssistantSearch(Map<String, dynamic> data) {
  return listingDataIsPubliclyDiscoverable(data);
}

/// No listings after search (+ optional findSimilar); offline hint + traditional search (X).
const String _assistantNoResultsAr =
    'ما لقيت نفس طلبك بالضبط حالياً، لكن أقدر أتابع لك أول ما ينزل عقار مناسب لك 👌\n\n'
    'خلّني أعرف ميزانيتك أو إذا تبي أوسّع لك البحث.\n\n'
    'وإذا حاب، أقدر أبلّغك مباشرة أول ما ينزل شيء قريب من طلبك.\n\n'
    'أقدر كمان:\n'
    '1. أبحث لك في مناطق قريبة\n'
    '2. أعرض لك العقارات المتوفرة\n'
    '3. أسجّل اهتمامك وأوصّلك إشعار أول ما يصير إعلان جديد.\n\n'
    'إذا ما عندك نت، تأكد من الاتصال ثم أعد الإرسال. تقدر تستخدم البحث العادي من أيقونة X.';

const String _assistantNoResultsEn =
    'I couldn\'t find an exact match for what you asked for right now, but I can follow up as soon as something suitable is listed.\n\n'
    'Tell me your budget, or if you\'d like me to widen the search.\n\n'
    'If you want, I can notify you as soon as something close to your request goes live.\n\n'
    'I can also:\n'
    '1. Search nearby areas\n'
    '2. Show available listings\n'
    '3. Save your interest so you get an alert when a new listing appears.\n\n'
    'If you\'re offline, reconnect and try again. You can also use traditional search (X).';

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
    }
  }

  /// فلاتر البحث الحالية (من الـ Agent)
  Map<String, dynamic> _currentFilters = {};

  /// نتائج آخر استعلام — للرد على المتابعة ولتأليف الرد التسويقي
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _lastResults = [];

  /// True after a no-results reply that offered to notify; next short confirmation saves interest explicitly.
  bool _awaitingNotifyConsent = false;

  /// مناطق قريبة للـ fallback عند عدم وجود نتائج في المنطقة المطلوبة (areaCode → قائمة areaCode)
  static const Map<String, List<String>> _nearbyAreaCodes = {
    'qadisiya': ['rawda', 'kaifan', 'khaldiya'],
    'nuzha': ['faiha', 'daeya', 'shamiya'],
    'shamiya': ['kaifan', 'daeya', 'rawda'],
  };

  /// Same area labels as listing cards ([areaArToEn] + [propertyLocationCode]).
  String _areaUiLabel(String areaCode) =>
      areaLabelForCode(areaCode, arabic: _isAr);

  static const String _welcomeAr =
      'هلا وغلا! أنا مساعدك في عقار أي. تقدر تسألني عن أي عقار، أسعار الإيجار بالشاليهات، أو أسعار العقار في أي منطقة مثل القادسية. ولا تتردد، أي سؤال؟';
  static const String _welcomeEn =
      'Welcome! I\'m your AqarAi assistant. Ask me about any property, chalet rental prices, or prices in any area. What would you like to know?';

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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PropertyDetailsPage(
          propertyId: id,
          captionTrackingId:
              (cid != null && cid.isNotEmpty) ? cid : null,
          leadSource: DealLeadSource.direct,
        ),
      ),
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
        final isAdmin = (await user?.getIdTokenResult(true))?.claims?['admin'] == true;
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
          } catch (_) {}
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
        } catch (_) {}
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
              .trim();
        }
        if (top3ListRef.isNotEmpty && refReply.isEmpty) {
          refReply = _isAr
              ? 'لقيت لك بعض الخيارات أدناه. قل لي إذا تبي تفاصيل أكثر.'
              : 'Here are some options below. Ask if you want more detail.';
        }
        final areaNameRef =
            areaCodeRef.isNotEmpty ? _areaUiLabel(areaCodeRef) : null;
        final propertyTypeRef = _currentFilters['type']?.toString().trim();
        final serviceTypeRef = _currentFilters['serviceType']?.toString().trim();
        final refSuggestions = _buildSmartSuggestions(
          area: areaNameRef,
          propertyType: propertyTypeRef?.isNotEmpty == true ? propertyTypeRef : null,
          serviceType: serviceTypeRef?.isNotEmpty == true ? serviceTypeRef : null,
          isAr: _isAr,
        );
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
            : (_isAr ? 'في أي منطقة تبحث؟' : 'Which area are you looking in?');
        _appendReply(msg);
        return;
      }

      if (_currentFilters['areaCode'] == null || _currentFilters['areaCode'].toString().trim().isEmpty) {
        _appendReply(_isAr ? 'حدد المنطقة (مثل: القادسية، النزهة) عشان أبحث.' : 'Specify the area (e.g. Qadisiya, Nuzha) to search.');
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
        if (areaCode.isNotEmpty &&
            _currentFilters['type'] != null &&
            nearbyCodesForSimilar != null &&
            nearbyCodesForSimilar.isNotEmpty) {
          try {
            final similarResult = await aiBrain.findSimilarRecommendations(
              requestedAreaCode: areaCode,
              propertyType: _currentFilters['type']!.toString().trim(),
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
              ? 'لقيت لك بعض الخيارات أدناه. قل لي إذا تبي تفاصيل أو تغيّر البحث.'
              : 'Here are some options below. Say if you want more detail or to adjust your search.';
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
      final suggestions = _buildSmartSuggestions(
        area: areaName,
        propertyType: propertyType?.isNotEmpty == true ? propertyType : null,
        serviceType: serviceType?.isNotEmpty == true ? serviceType : null,
        isAr: _isAr,
      );
      final isNoResultsNotifyFallback =
          top3List.isEmpty && (replyResults == null || replyResults.isEmpty);
      _awaitingNotifyConsent = isNoResultsNotifyFallback;
      _appendReply(
        reply,
        results: replyResults,
        suggestions: suggestions.isNotEmpty ? suggestions : null,
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

  /// Build contextual suggestion buttons based on current search filters.
  List<String> _buildSmartSuggestions({
    String? area,
    String? propertyType,
    String? serviceType,
    bool isAr = true,
  }) {
    final suggestions = <String>[];
    if (isAr) {
      if (area != null && area.isNotEmpty) {
        suggestions.add('أرخص شوي في $area');
        suggestions.add('نفس النوع في مناطق قريبة');
      }
      if (propertyType == 'house') {
        suggestions.add('شقق في نفس المنطقة');
      }
      if (propertyType == 'apartment') {
        suggestions.add('بيوت في نفس المنطقة');
      }
      if (serviceType == 'sale') {
        suggestions.add('للإيجار في نفس المنطقة');
      }
    } else {
      if (area != null && area.isNotEmpty) {
        suggestions.add('Cheaper options in $area');
        suggestions.add('Same type in nearby areas');
      }
      if (propertyType == 'house') {
        suggestions.add('Apartments in same area');
      }
      if (propertyType == 'apartment') {
        suggestions.add('Houses in same area');
      }
      if (serviceType == 'sale') {
        suggestions.add('For rent in same area');
      }
    }
    return suggestions.take(3).toList();
  }

  void _appendReply(
    String text, {
    List<Map<String, dynamic>>? results,
    List<String>? suggestions,
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
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
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
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PropertyDetailsPage(
                                      propertyId: id,
                                      leadSource: DealLeadSource.aiChat,
                                    ),
                                  ),
                                );
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
                      children: msg.suggestions!.map((s) {
                        return GestureDetector(
                          onTap: () => _sendMessage(s),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF1F1F1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    s,
                                    style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
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

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  /// When non-null and non-empty, show up to 3 property cards under this (assistant) message.
  final List<Map<String, dynamic>>? results;
  /// Optional quick-reply suggestions shown under assistant messages.
  final List<String>? suggestions;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.results,
    this.suggestions,
  });
}
