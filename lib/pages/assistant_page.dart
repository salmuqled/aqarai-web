// lib/pages/assistant_page.dart
// شاشة المساعد الذكي — أول ما يفتح التطبيق، مع زر X للبحث التقليدي
// استدعاء الدالة عبر HTTP لتجنب مشكلة GTMSessionFetcher على iOS

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:aqarai_app/home_page.dart';

const String _assistantUrl =
    'https://us-central1-aqarai-caf5d.cloudfunctions.net/aqaraiAssistant';

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

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('unauthenticated');
      }
      final idToken = await user.getIdToken(true);
      final locale = _isAr ? 'ar' : 'en';
      final body = jsonEncode({
        'data': {'message': text, 'locale': locale},
      });
      final response = await http
          .post(
            Uri.parse(_assistantUrl),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60));

      String reply;
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>?;
        final result = json?['result'] as Map<String, dynamic>?;
        reply = result?['reply'] as String? ??
            (_isAr ? 'ما قدرت أفهم، جرب مرة ثانية.' : 'Could not get a reply. Try again.');
      } else {
        try {
          final json = jsonDecode(response.body) as Map<String, dynamic>?;
          final err = json?['error'] as Map<String, dynamic>?;
          final msg = err?['message'] as String?;
          reply = msg ?? (_isAr ? 'حصل خطأ. جرب مرة ثانية.' : 'Something went wrong. Try again.');
        } catch (_) {
          reply = _isAr ? 'حصل خطأ. جرب مرة ثانية.' : 'Something went wrong. Try again.';
        }
      }
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(text: reply, isUser: false, timestamp: DateTime.now()));
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          text: _isAr
              ? 'حصل خطأ بالاتصال. تأكد من النت وجرب مرة ثانية، أو اضغط X للبحث العادي.'
              : 'Connection error. Check your network or tap X for traditional search.',
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _isLoading = false;
      });
      _scrollToBottom();
    }
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
