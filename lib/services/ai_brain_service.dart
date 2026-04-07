// lib/services/ai_brain_service.dart
//
// =============================================================================
// ARCHITECTURE: AI Real Estate Agent (From Bot to Agent)
// =============================================================================
//
// Context policy (sent to OpenAI via Cloud Function):
//   - Last 8 chat messages (role + content only).
//   - Compact currentFilters: areaCode, type, serviceType, budget, bedrooms.
//   - Top 3 last results: propertyId, price, area, propertyType, rank (1–3) for reference_listing (الأرخص، الثاني، …).
//
// OPENAI_API_KEY: Stored in Firebase (backend only). See "Adding OPENAI_API_KEY"
// section at the bottom of this file.
//
// =============================================================================

import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

const String _baseUrl = 'https://us-central1-aqarai-caf5d.cloudfunctions.net';

/// Result of AI analysis: intent, params patch, reset flag, completion, clarifying questions
class AgentAnalyzeResult {
  final String intent;
  final Map<String, dynamic> paramsPatch;
  final bool resetFilters;
  final bool isComplete;
  final List<String> clarifyingQuestions;
  final String? referencedPropertyId;

  AgentAnalyzeResult({
    required this.intent,
    required this.paramsPatch,
    required this.resetFilters,
    required this.isComplete,
    required this.clarifyingQuestions,
    this.referencedPropertyId,
  });

  static AgentAnalyzeResult fromJson(Map<String, dynamic> json) {
    final patch = json['params_patch'];
    final list = json['clarifying_questions'];
    final refRaw = json['referenced_property_id']?.toString().trim();
    return AgentAnalyzeResult(
      intent: (json['intent'] ?? 'general_question').toString(),
      paramsPatch: patch is Map ? Map<String, dynamic>.from(patch) : {},
      resetFilters: json['reset_filters'] == true,
      isComplete: json['is_complete'] == true,
      clarifyingQuestions: list is List ? list.map((e) => e.toString()).toList() : [],
      referencedPropertyId: (refRaw != null && refRaw.isNotEmpty) ? refRaw : null,
    );
  }
}

/// Service that calls backend (GPT-4o mini) for intent analysis and marketing reply.
///
/// Backend uses OpenAI gpt-4o-mini with a Kuwaiti real estate expert system prompt.
/// Output is strict JSON: intent, params_patch, reset_filters, is_complete, clarifying_questions.
/// If area is missing, backend returns is_complete: false and a question in clarifying_questions.
class AiBrainService {
  /// Analyzes the user message and returns structured JSON for the real estate assistant.
  ///
  /// Uses OpenAI gpt-4o-mini via Cloud Function. Converts Arabic/Kuwaiti terms to
  /// search params (e.g. القادسية -> qadisiya, بيت -> house).
  ///
  /// Returns a map with: intent, params_patch, reset_filters, is_complete, clarifying_questions.
  /// If area is missing, is_complete is false and clarifying_questions contains a question.
  Future<Map<String, dynamic>> analyzeMessage({
    required String message,
    required List<Map<String, String>> chatHistory,
    Map<String, dynamic>? currentFilters,
    List<Map<String, dynamic>> top3LastResults = const [],
    String locale = 'ar',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('User must be signed in to analyze messages');
    }
    final idToken = await user.getIdToken(true);
    if (idToken == null || idToken.isEmpty) {
      throw Exception('Could not get auth token');
    }
    final last8 = chatHistory.length > 8 ? chatHistory.sublist(chatHistory.length - 8) : chatHistory;
    final result = await analyze(
      message: message,
      last8Messages: last8,
      currentFilters: currentFilters ?? {},
      top3LastResults: top3LastResults,
      idToken: idToken,
      locale: locale,
    );
    return <String, dynamic>{
      'intent': result.intent,
      'params_patch': result.paramsPatch,
      'reset_filters': result.resetFilters,
      'is_complete': result.isComplete,
      'clarifying_questions': result.clarifyingQuestions,
      if (result.referencedPropertyId != null && result.referencedPropertyId!.isNotEmpty)
        'referenced_property_id': result.referencedPropertyId,
    };
  }

  /// Analyze user message with context; returns structured result for Agent flow
  Future<AgentAnalyzeResult> analyze({
    required String message,
    required List<Map<String, String>> last8Messages,
    required Map<String, dynamic> currentFilters,
    required List<Map<String, dynamic>> top3LastResults,
    required String idToken,
    String locale = 'ar',
  }) async {
    final body = jsonEncode({
      'data': {
        'message': message,
        'last8Messages': last8Messages,
        'currentFilters': currentFilters,
        'top3LastResults': top3LastResults,
        'locale': locale,
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

  /// Rank property results by score (area match, nearby, featured, recency, budget).
  /// Returns top 3 only; does not modify Firestore. Use before compose when you have many results.
  Future<List<Map<String, dynamic>>> rankResults({
    required List<Map<String, dynamic>> properties,
    required String requestedAreaCode,
    List<String> nearbyAreaCodes = const [],
    double? userBudget,
    required String idToken,
  }) async {
    if (properties.isEmpty) return [];
    final body = jsonEncode({
      'data': {
        'properties': properties,
        'requestedAreaCode': requestedAreaCode,
        'nearbyAreaCodes': nearbyAreaCodes,
        'userBudget': userBudget,
      },
    });
    final response = await http
        .post(
          Uri.parse('$_baseUrl/aqaraiAgentRankResults'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      if (response.statusCode == 404) {
        throw Exception(
          'Agent rank failed: 404 (backend may not be deployed). Run: cd functions && npm run build && firebase deploy --only functions',
        );
      }
      throw Exception('Agent rank failed: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>?;
    final result = json?['result'] as Map<String, dynamic>?;
    final top3 = result?['top3'] as List<dynamic>?;
    if (top3 == null) return [];
    return top3.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// When main + nearby both return 0, get similar property recommendations from backend.
  /// Returns reply text and list of recommendation maps (id, areaAr, areaEn, type, price, size).
  Future<Map<String, dynamic>> findSimilarRecommendations({
    required String requestedAreaCode,
    required String propertyType,
    required String idToken,
    List<String> nearbyAreaCodes = const [],
    double? userBudget,
  }) async {
    final body = jsonEncode({
      'data': {
        'requestedAreaCode': requestedAreaCode,
        'propertyType': propertyType,
        'nearbyAreaCodes': nearbyAreaCodes,
        'userBudget': userBudget,
        'locale': 'ar',
      },
    });
    final response = await http
        .post(
          Uri.parse('$_baseUrl/aqaraiAgentFindSimilar'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Find similar failed: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>?;
    final result = json?['result'] as Map<String, dynamic>?;
    final reply = result?['reply']?.toString() ?? '';
    final recs = result?['recommendations'] as List<dynamic>?;
    final recommendations = recs != null ? recs.map((e) => Map<String, dynamic>.from(e as Map)).toList() : <Map<String, dynamic>>[];
    return {'reply': reply, 'recommendations': recommendations};
  }

  /// Generate marketing-style reply from top 3 results (Kuwaiti tone, one next question).
  /// When [userAskedForMore] is true and there is only one result, backend returns
  /// a message offering to search nearby areas instead of repeating the property.
  /// [rawMessage] is the user's last message, used for buyer intent (investment vs residential).
  Future<String> composeMarketingReply({
    required List<Map<String, dynamic>> top3Results,
    required String idToken,
    bool isAr = true,
    bool userAskedForMore = false,
    bool isNearbyFallback = false,
    String requestedAreaLabel = '',
    String rawMessage = '',
  }) async {
    final body = jsonEncode({
      'data': {
        'top3Results': top3Results,
        'locale': isAr ? 'ar' : 'en',
        'userAskedForMore': userAskedForMore,
        'isNearbyFallback': isNearbyFallback,
        'requestedAreaLabel': requestedAreaLabel,
        if (rawMessage.isNotEmpty) 'rawMessage': rawMessage,
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

// =============================================================================
// Adding OPENAI_API_KEY to environment (backend only)
// =============================================================================
//
// The AI analysis runs in Firebase Cloud Functions (aqaraiAgentAnalyze), not in
// the app. The API key must NEVER be stored in the Flutter app.
//
// 1) Firebase Functions (recommended)
//    cd functions
//    firebase functions:secrets:set OPENAI_API_KEY
//    When prompted, paste your OpenAI API key (starts with sk-...).
//
// 2) Redeploy the function so it picks up the secret:
//    npm run build && firebase deploy --only functions:aqaraiAgentAnalyze
//
// 3) Get an API key from https://platform.openai.com/api-keys
//    Ensure the key has access to the gpt-4o-mini model and billing is enabled.
// =============================================================================
