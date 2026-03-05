// lib/pages/assistant_page.dart
//
// =============================================================================
// ARCHITECTURE: AI Real Estate Agent (logic only; no UI changes)
// =============================================================================
// State: _currentFilters (Map), _lastResults (List<QueryDocumentSnapshot>).
//
// Flow in _sendMessage():
//   1) User message -> AiBrainService.analyze(message, last8Messages, _currentFilters, top3LastResults)
//   2) If intent == greeting -> reply friendly, stop
//   3) If reset_filters == true -> clear _currentFilters and _lastResults
//   4) Merge params_patch into _currentFilters (only overwrite keys where value != null)
//   5) If is_complete == false -> reply with clarifying_questions, stop
//   6) If areaCode missing -> reply ask area, stop
//   7) Run Firestore search: ConversationalSearchService.buildQueryFromMap(_currentFilters)
//      (Maps: type->type, areaCode->areaCode, serviceType->serviceType, budget->price<=budget)
//   8) Save results in _lastResults; keep _currentFilters
//   9) Send top 3 results to AiBrainService.composeMarketingReply(...) -> marketing-style reply
//  10) Append reply to _messages
//
// Step-by-step tests:
//   a) "السلام عليكم" -> greeting reply, stop
//   b) "ابي بيت للبيع بالقادسية" -> search, marketing reply with 1-3 options + one question
//   c) "ابي أرخص" -> budget -10% or ask budget; then search or clarify
//   d) "كم غرفة؟" -> clarifying_questions or params_patch.bedrooms
//   e) "غير المنطقة للنزهة" -> reset_filters, areaCode=nuzha, search
// =============================================================================

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:aqarai_app/home_page.dart';
import 'package:aqarai_app/services/ai_brain_service.dart';
import 'package:aqarai_app/services/conversational_search_service.dart';

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

  /// فلاتر البحث الحالية (من الـ Agent)
  Map<String, dynamic> _currentFilters = {};

  /// نتائج آخر استعلام — للرد على المتابعة ولتأليف الرد التسويقي
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _lastResults = [];

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
      final last8 = _last8Messages();
      final top3ForContext = _top3ShortResults();

      final analyzeResult = await aiBrain.analyze(
        message: text,
        last8Messages: last8,
        currentFilters: Map<String, dynamic>.from(_currentFilters),
        top3LastResults: top3ForContext,
        idToken: idToken,
      );

      if (analyzeResult.intent == 'greeting') {
        _appendReply(_isAr ? 'هلا وغلا! كيف أقدر أساعدك؟ اكتب المنطقة ونوع العقار (مثل: ابي بيت للبيع في القادسية).' : 'Hi! How can I help? Type area and property type (e.g. house for sale in Qadisiya).');
        return;
      }

      if (analyzeResult.resetFilters) {
        setState(() {
          _currentFilters = {};
          _lastResults = [];
        });
      }

      for (final e in analyzeResult.paramsPatch.entries) {
        if (e.value != null) {
          _currentFilters[e.key] = e.value;
        }
      }

      if (!analyzeResult.isComplete) {
        final msg = analyzeResult.clarifyingQuestions.isNotEmpty
            ? analyzeResult.clarifyingQuestions.join('\n')
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

      final top3List = _lastResults.take(3).map((doc) {
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

      String reply;
      if (top3List.isEmpty) {
        reply = _isAr ? 'ما لقيت عقارات تطابق الفلاتر. جرب منطقة أو ميزانية ثانية.' : 'No properties match. Try different area or budget.';
      } else {
        reply = await aiBrain.composeMarketingReply(top3Results: top3List, idToken: idToken, isAr: _isAr);
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
