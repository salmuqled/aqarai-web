// lib/pages/assistant_page.dart
//
// =============================================================================
// ARCHITECTURE: AI Real Estate Agent (logic only; no UI changes)
// =============================================================================
// State: _currentFilters (Map), _lastResults (List<QueryDocumentSnapshot>).
//
// Flow in _sendMessage():
//   1) AiBrainService.analyzeMessage(message: text, chatHistory: lastMessages, currentFilters: _currentFilters)
//   2) If intent == greeting -> append friendly message, stop
//   3) If reset_filters == true -> clear _currentFilters and _lastResults
//   4) Merge params_patch into _currentFilters
//   5) If is_complete == false -> append clarifying_questions, stop
//   6) Run Firestore search: ConversationalSearchService (areaCode, type, serviceType, budget -> price <= budget)
//   7) Save results to _lastResults
//   8) Save buyer interest (UserInterestService) if user signed in and filters non-empty; ignore errors
//   9) Send top 3 to aqaraiAgentCompose (composeMarketingReply), append reply
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
import 'package:flutter/material.dart';
import 'package:aqarai_app/home_page.dart';
import 'package:aqarai_app/services/ai_brain_service.dart';
import 'package:aqarai_app/services/conversational_search_service.dart';
import 'package:aqarai_app/services/user_interest_service.dart';
import 'package:aqarai_app/services/notification_service.dart';
import 'package:aqarai_app/widgets/listing_card.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';

class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  bool _assistantTyping = false;
  bool _isAr = true;
  bool _fcmSetupDone = false;

  /// فلاتر البحث الحالية (من الـ Agent)
  Map<String, dynamic> _currentFilters = {};

  /// نتائج آخر استعلام — للرد على المتابعة ولتأليف الرد التسويقي
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _lastResults = [];

  /// مناطق قريبة للـ fallback عند عدم وجود نتائج في المنطقة المطلوبة (areaCode → قائمة areaCode)
  static const Map<String, List<String>> _nearbyAreaCodes = {
    'qadisiya': ['rawda', 'kaifan', 'khaldiya'],
    'nuzha': ['faiha', 'daeya', 'shamiya'],
    'shamiya': ['kaifan', 'daeya', 'rawda'],
  };

  /// تسمية المنطقة للرسالة (areaCode → عرض عربي)
  static const Map<String, String> _areaCodeToLabel = {
    'qadisiya': 'القادسية',
    'nuzha': 'النزهة',
    'shamiya': 'الشامية',
  };

  static const String _welcomeAr =
      'هلا وغلا! أنا مساعدك في عقار أي. تقدر تسألني عن أي عقار، أسعار الإيجار بالشاليهات، أو أسعار العقار في أي منطقة مثل القادسية. ولا تتردد، أي سؤال؟';
  static const String _welcomeEn =
      'Welcome! I\'m your AqarAi assistant. Ask me about any property, chalet rental prices, or prices in any area. What would you like to know?';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
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
      final idToken = await user.getIdToken(true);
      if (idToken == null || idToken.isEmpty) {
        _appendReply(_isAr ? 'ما قدرت أتحقق من الدخول. جرّب مرة ثانية.' : 'Could not verify sign-in. Try again.');
        return;
      }

      final aiBrain = AiBrainService();
      final lastMessages = _last8Messages();

      final result = await aiBrain.analyzeMessage(
        message: text,
        chatHistory: lastMessages,
        currentFilters: _currentFilters.isEmpty ? null : Map<String, dynamic>.from(_currentFilters),
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
      final query = searchService.buildQueryFromMap(_currentFilters);
      final snapshot = await query.limit(30).get();
      final docs = snapshot.docs;
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

      List<Map<String, dynamic>> top3List;
      bool isNearbyFallback = false;
      String requestedAreaLabel = '';

      if (_lastResults.isNotEmpty) {
        final propsForRank = _buildPropsForRank(_lastResults);
        top3List = await aiBrain.rankResults(
          properties: propsForRank,
          requestedAreaCode: areaCode,
          nearbyAreaCodes: [],
          userBudget: userBudget,
          idToken: idToken,
        );
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
      } else {
        top3List = [];
      }

      if (top3List.isEmpty) {
        final nearbyCodes = areaCode.isNotEmpty ? _nearbyAreaCodes[areaCode] : null;
        if (nearbyCodes != null && nearbyCodes.isNotEmpty) {
          final nearbyQuery = searchService.buildQueryNearbyFromMap(_currentFilters, nearbyCodes);
          final nearbySnapshot = await nearbyQuery.get();
          final nearbyDocs = nearbySnapshot.docs;
          if (nearbyDocs.isNotEmpty && mounted) {
            setState(() {
              _lastResults = List.from(nearbyDocs);
            });
            final propsForRank = _buildPropsForRank(_lastResults);
            top3List = await aiBrain.rankResults(
              properties: propsForRank,
              requestedAreaCode: areaCode,
              nearbyAreaCodes: nearbyCodes,
              userBudget: userBudget,
              idToken: idToken,
            );
            if (top3List.isEmpty) {
              top3List = _lastResults.take(3).map((doc) {
                final d = doc.data();
                return <String, dynamic>{
                  'id': doc.id,
                  'areaAr': d['areaAr'],
                  'areaEn': d['areaEn'],
                  'type': d['type'],
                  'price': d['price'],
                  'size': d['size'],
                };
              }).toList();
            } else {
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
            isNearbyFallback = true;
            requestedAreaLabel = _areaCodeToLabel[areaCode] ?? areaCode;
          }
        }
      }

      final userAskedForMore = _userAskedForMoreOptions(text);

      String reply;
      List<Map<String, dynamic>>? replyResults;
      if (top3List.isEmpty) {
        final nearbyCodesForSimilar = areaCode.isNotEmpty ? _nearbyAreaCodes[areaCode] : null;
        if (areaCode.isNotEmpty &&
            _currentFilters['type'] != null &&
            nearbyCodesForSimilar != null &&
            nearbyCodesForSimilar.isNotEmpty) {
          try {
            final similarResult = await aiBrain.findSimilarRecommendations(
              requestedAreaCode: areaCode,
              propertyType: _currentFilters['type']!.toString().trim(),
              idToken: idToken,
              nearbyAreaCodes: nearbyCodesForSimilar,
              userBudget: userBudget,
            );
            final similarReply = similarResult['reply']?.toString() ?? '';
            final recs = similarResult['recommendations'] as List<dynamic>?;
            if (similarReply.isNotEmpty && recs != null && recs.isNotEmpty) {
              reply = similarReply;
              replyResults = recs.take(3).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            } else {
              reply = _isAr
                  ? 'حالياً ما لقيت عقار مطابق في هذه المنطقة.\n\nأقدر:\n1) أبحث في مناطق قريبة\n2) أعرض كل العقارات المتوفرة\n3) أسجلك كمهتم وأرسل لك إشعار إذا نزل إعلان جديد.'
                  : 'No matching property in this area right now.\n\nI can:\n1) Search nearby areas\n2) Show all available properties\n3) Register your interest and notify you when a new listing appears.';
            }
          } catch (_) {
            reply = _isAr
                ? 'حالياً ما لقيت عقار مطابق في هذه المنطقة.\n\nأقدر:\n1) أبحث في مناطق قريبة\n2) أعرض كل العقارات المتوفرة\n3) أسجلك كمهتم وأرسل لك إشعار إذا نزل إعلان جديد.'
                : 'No matching property in this area right now.\n\nI can:\n1) Search nearby areas\n2) Show all available properties\n3) Register your interest and notify you when a new listing appears.';
          }
        } else {
          reply = _isAr
              ? 'حالياً ما لقيت عقار مطابق في هذه المنطقة.\n\nأقدر:\n1) أبحث في مناطق قريبة\n2) أعرض كل العقارات المتوفرة\n3) أسجلك كمهتم وأرسل لك إشعار إذا نزل إعلان جديد.'
              : 'No matching property in this area right now.\n\nI can:\n1) Search nearby areas\n2) Show all available properties\n3) Register your interest and notify you when a new listing appears.';
        }
      } else {
        reply = await aiBrain.composeMarketingReply(
          top3Results: top3List,
          idToken: idToken,
          isAr: _isAr,
          userAskedForMore: userAskedForMore,
          isNearbyFallback: isNearbyFallback,
          requestedAreaLabel: requestedAreaLabel,
          rawMessage: text,
        );
        replyResults = top3List.take(3).map((e) => Map<String, dynamic>.from(e)).toList();
      }
      final areaName = areaCode.isNotEmpty ? (_areaCodeToLabel[areaCode] ?? areaCode) : null;
      final propertyType = _currentFilters['type']?.toString().trim();
      final serviceType = _currentFilters['serviceType']?.toString().trim();
      final suggestions = _buildSmartSuggestions(
        area: areaName,
        propertyType: propertyType?.isNotEmpty == true ? propertyType : null,
        serviceType: serviceType?.isNotEmpty == true ? serviceType : null,
        isAr: _isAr,
      );
      _appendReply(
        reply,
        results: replyResults,
        suggestions: suggestions.isNotEmpty ? suggestions : null,
      );
    } catch (e, st) {
      debugPrint('Assistant _sendMessage error: $e');
      debugPrint('Stack trace: $st');
      final isNetworkError = e is SocketException ||
          e is TimeoutException ||
          e is HandshakeException ||
          (e is OSError && _isNetworkOsError(e.errorCode));
      final message = isNetworkError
          ? (_isAr
              ? 'ما في اتصال بالنت أو السيرفر مو واصل. تأكد من النت وجرب مرة ثانية، أو اضغط X للبحث العادي.'
              : 'No internet or server unreachable. Check your network and try again, or tap X for traditional search.')
          : (_isAr
              ? 'حصل خطأ بالاتصال. تأكد من النت وجرب مرة ثانية، أو اضغط X للبحث العادي.'
              : 'Connection error. Check your network or tap X for traditional search.');
      _appendReply(message);
    }
  }

  /// True for common OS error codes that mean network unreachable / no route.
  static bool _isNetworkOsError(int? code) {
    if (code == null) return false;
    // 50 = Network is down (macOS/iOS), 51 = Network unreachable, 61 = Connection refused, etc.
    return const [50, 51, 61, 64, 65].contains(code);
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
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0D1117),
              Color(0xFF161B22),
              Color(0xFF0D1117),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // هيدر: عنوان + زر إغلاق X
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, color: Colors.amber[300], size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isAr ? 'مساعدك العقاري' : 'Your Property Assistant',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Material(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: _closeToTraditionalSearch,
                        borderRadius: BorderRadius.circular(12),
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.close, color: Colors.white, size: 24),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                isAr ? 'اضغط X للبحث التقليدي' : 'Tap X for traditional search',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),

              // قائمة الرسائل
              Expanded(
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

              // حقل الإدخال
              Container(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
                color: Colors.black26,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onSubmitted: (_) => _sendMessage(),
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        decoration: InputDecoration(
                          hintText: isAr ? 'اكتب سؤالك هنا...' : 'Type your question...',
                          hintStyle: TextStyle(color: Colors.white54, fontSize: 15),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.1),
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
                      color: const Color(0xFF238636),
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
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.isUser;
    final assistantResults = msg.results != null && msg.results!.isNotEmpty
        ? msg.results!.take(3).toList()
        : <Map<String, dynamic>>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: isUser
          ? Align(
              alignment: Alignment.centerRight,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F5D56),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  msg.text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: Colors.grey.shade300,
                  child: Icon(Icons.smart_toy, size: 16, color: Colors.grey.shade600),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F2F2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          msg.text,
                          style: TextStyle(
                            color: Colors.black87,
                            fontSize: 15,
                            height: 1.4,
                          ),
                        ),
                      ),
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
                                          builder: (_) => PropertyDetailsPage(propertyId: id),
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
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    s,
                                    style: const TextStyle(fontSize: 14),
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

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.grey.shade300,
            child: Icon(Icons.smart_toy, size: 16, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              "...",
              style: TextStyle(
                fontSize: 15,
                color: Colors.black87,
              ),
            ),
          ),
        ],
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
