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

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:aqarai_app/home_page.dart';
import 'package:aqarai_app/services/ai_brain_service.dart';
import 'package:aqarai_app/services/conversational_search_service.dart';
import 'package:aqarai_app/services/user_interest_service.dart';
import 'package:aqarai_app/services/notification_service.dart';

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

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    _isLoading = true;
    _controller.clear();
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true, timestamp: DateTime.now()));
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
        _appendReply(_isAr ? 'هلا وغلا! كيف أقدر أساعدك؟ اكتب المنطقة ونوع العقار (مثل: ابي بيت للبيع في القادسية).' : 'Hi! How can I help? Type area and property type (e.g. house for sale in Qadisiya).');
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
      final snapshot = await query.limit(10).get();
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

      List<Map<String, dynamic>> top3List = _top3ShortResults();
      final userAskedForMore = _userAskedForMoreOptions(text);
      bool isNearbyFallback = false;
      String requestedAreaLabel = '';

      if (top3List.isEmpty) {
        final areaCode = _currentFilters['areaCode']?.toString().trim();
        final nearbyCodes = areaCode != null ? _nearbyAreaCodes[areaCode] : null;
        if (nearbyCodes != null && nearbyCodes.isNotEmpty) {
          final nearbyQuery = searchService.buildQueryNearbyFromMap(_currentFilters, nearbyCodes);
          final nearbySnapshot = await nearbyQuery.get();
          final nearbyDocs = nearbySnapshot.docs;
          if (nearbyDocs.isNotEmpty && mounted) {
            setState(() {
              _lastResults = List.from(nearbyDocs);
            });
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
            isNearbyFallback = true;
            requestedAreaLabel = _areaCodeToLabel[areaCode] ?? areaCode ?? '';
          }
        }
      }

      String reply;
      if (top3List.isEmpty) {
        reply = _isAr
            ? 'حالياً ما لقيت عقار مطابق في هذه المنطقة.\n\nأقدر:\n1) أبحث في مناطق قريبة\n2) أعرض كل العقارات المتوفرة\n3) أسجلك كمهتم وأرسل لك إشعار إذا نزل إعلان جديد.'
            : 'No matching property in this area right now.\n\nI can:\n1) Search nearby areas\n2) Show all available properties\n3) Register your interest and notify you when a new listing appears.';
      } else {
        reply = await aiBrain.composeMarketingReply(
          top3Results: top3List,
          idToken: idToken,
          isAr: _isAr,
          userAskedForMore: userAskedForMore,
          isNearbyFallback: isNearbyFallback,
          requestedAreaLabel: requestedAreaLabel,
        );
      }
      _appendReply(reply);
    } catch (e) {
      _appendReply(_isAr ? 'حصل خطأ بالاتصال. تأكد من النت وجرب مرة ثانية، أو اضغط X للبحث العادي.' : 'Connection error. Check your network or tap X for traditional search.');
    }
  }

  void _appendReply(String text) {
    if (!mounted) return;
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: false, timestamp: DateTime.now()));
      _isLoading = false;
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

  List<Map<String, dynamic>> _top3ShortResults() {
    return _lastResults.take(3).map((doc) {
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
                  itemCount: _messages.length + (_isLoading ? 1 : 0),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser)
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.amber.withOpacity(0.3),
              child: Icon(Icons.smart_toy_rounded, color: Colors.amber[200], size: 20),
            ),
          if (!isUser) const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser
                    ? const Color(0xFF238636).withOpacity(0.9)
                    : Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(isUser ? 20 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 20),
                ),
              ),
              child: Text(
                msg.text,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 10),
          if (isUser)
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.blue.withOpacity(0.4),
              child: const Icon(Icons.person, color: Colors.white70, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.amber.withOpacity(0.3),
            child: Icon(Icons.smart_toy_rounded, color: Colors.amber[200], size: 20),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(20),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dot(),
                const SizedBox(width: 6),
                _dot(),
                const SizedBox(width: 6),
                _dot(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot() {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.7),
        shape: BoxShape.circle,
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({required this.text, required this.isUser, required this.timestamp});
}
