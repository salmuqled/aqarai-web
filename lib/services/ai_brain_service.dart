// lib/services/ai_brain_service.dart
//
// =============================================================================
// ARCHITECTURE: AI Real Estate Agent (From Bot to Agent)
// =============================================================================
//
// Context policy (sent to OpenAI):
//   - Last 8 chat messages (role + content only).
//   - Compact currentFilters: areaCode, type, serviceType, budget, bedrooms.
//   - Top 3 last results as short objects: id, areaAr, areaEn, type, price, size.
//
// Flow:
//
//   [User Message] --> AssistantPage._sendMessage()
//          |
//          v
//   AiBrainService.analyze(message, last8Messages, _currentFilters, top3LastResults)
//          |  HTTP POST --> aqaraiAgentAnalyze (GPT-4o mini)
//          |  Output: STRICT JSON { intent, params_patch, reset_filters, is_complete, clarifying_questions }
//          v
//   AssistantPage:
//     - intent == greeting  --> reply friendly, stop
//     - reset_filters == true --> clear _currentFilters & _lastResults
//     - merge params_patch into _currentFilters (only non-null keys)
//     - is_complete == false --> reply with clarifying_questions, stop
//     - is_complete == true + areaCode present --> run Firestore search
//          |
//          v
//   ConversationalSearchService.buildQueryFromMap(_currentFilters)
//     Maps: type->type, areaCode->areaCode, serviceType->serviceType, budget->price<=budget
//   Save snapshot.docs to _lastResults; keep _currentFilters
//          |
//          v
//   AiBrainService.composeMarketingReply(top3, idToken, isAr)
//     HTTP POST --> aqaraiAgentCompose --> marketing reply (1-3 options, ONE next question)
//          |
//          v
//   Append reply to _messages
//
// =============================================================================
// Step-by-step tests (manual)
// =============================================================================
// a) "السلام عليكم"     --> intent=greeting, friendly reply, stop
// b) "ابي بيت للبيع بالقادسية" --> params_patch { areaCode, type, serviceType }, is_complete=true, search, marketing reply
// c) "ابي أرخص"        --> params_patch { budget: current*0.9 } or is_complete=false + ask budget
// d) "كم غرفة؟"        --> clarifying or params_patch.bedrooms; or general reply
// e) "غير المنطقة للنزهة" --> reset_filters=true, params_patch.areaCode=nuzha, then search
// =============================================================================

import 'dart:convert';

import 'package:http/http.dart' as http;

const String _baseUrl = 'https://us-central1-aqarai-caf5d.cloudfunctions.net';

/// Result of AI analysis: intent, params patch, reset flag, completion, clarifying questions
class AgentAnalyzeResult {
  final String intent;
  final Map<String, dynamic> paramsPatch;
  final bool resetFilters;
  final bool isComplete;
  final List<String> clarifyingQuestions;

  AgentAnalyzeResult({
    required this.intent,
    required this.paramsPatch,
    required this.resetFilters,
    required this.isComplete,
    required this.clarifyingQuestions,
  });

  static AgentAnalyzeResult fromJson(Map<String, dynamic> json) {
    final patch = json['params_patch'];
    final list = json['clarifying_questions'];
    return AgentAnalyzeResult(
      intent: (json['intent'] ?? 'general_question').toString(),
      paramsPatch: patch is Map ? Map<String, dynamic>.from(patch) : {},
      resetFilters: json['reset_filters'] == true,
      isComplete: json['is_complete'] == true,
      clarifyingQuestions: list is List ? list.map((e) => e.toString()).toList() : [],
    );
  }
}

/// Service that calls backend (GPT-4o mini) for intent analysis and marketing reply
class AiBrainService {
  /// Analyze user message with context; returns structured result for Agent flow
  Future<AgentAnalyzeResult> analyze({
    required String message,
    required List<Map<String, String>> last8Messages,
    required Map<String, dynamic> currentFilters,
    required List<Map<String, dynamic>> top3LastResults,
    required String idToken,
  }) async {
    final body = jsonEncode({
      'data': {
        'message': message,
        'last8Messages': last8Messages,
        'currentFilters': currentFilters,
        'top3LastResults': top3LastResults,
      },
    });
    final response = await http
        .post(
          Uri.parse('$_baseUrl/aqaraiAgentAnalyze'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Agent analyze failed: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>?;
    final result = json?['result'] as Map<String, dynamic>?;
    if (result == null) throw Exception('Invalid analyze response');
    return AgentAnalyzeResult.fromJson(result);
  }

  /// Generate marketing-style reply from top 3 results (Kuwaiti tone, one next question)
  Future<String> composeMarketingReply({
    required List<Map<String, dynamic>> top3Results,
    required String idToken,
    bool isAr = true,
  }) async {
    final body = jsonEncode({
      'data': {
        'top3Results': top3Results,
        'locale': isAr ? 'ar' : 'en',
      },
    });
    final response = await http
        .post(
          Uri.parse('$_baseUrl/aqaraiAgentCompose'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception('Agent compose failed: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>?;
    final reply = json?['result']?['reply'] ?? (json?['reply'] ?? '');
    return reply.toString().trim();
  }
}
