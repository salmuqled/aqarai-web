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
// Calls use FirebaseFunctions httpsCallable (us-central1); auth token is attached by the SDK.
//
// =============================================================================

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;

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

/// Top 3 ranked property maps plus composed reply (single `aqaraiAgentRankAndCompose` round-trip).
class AgentRankAndComposeResult {
  final List<Map<String, dynamic>> top3;
  final String reply;

  AgentRankAndComposeResult({required this.top3, required this.reply});
}

/// Reply text plus optional listing payloads from `aqaraiAgentCompose` (e.g. top-demand chalets).
class ComposeMarketingOutput {
  final String reply;
  final List<Map<String, dynamic>> results;

  const ComposeMarketingOutput({required this.reply, this.results = const []});
}

/// Service that calls backend (GPT-4o mini) for intent analysis and marketing reply.
///
/// Backend uses OpenAI gpt-4o-mini with a Kuwaiti real estate expert system prompt.
/// Output is strict JSON: intent, params_patch, reset_filters, is_complete, clarifying_questions.
/// If area is missing, backend returns is_complete: false and a question in clarifying_questions.
class AiBrainService {
  static const String _region = 'us-central1';

  static FirebaseFunctions _functions() => FirebaseFunctions.instanceFor(region: _region);

  static HttpsCallable _callable(String name) => _functions().httpsCallable(name);

  /// User-visible copy for assistant UI; covers callable codes, timeouts, and common network errors.
  static String userFacingErrorMessage(Object error, {required bool isArabic}) {
    if (error is FirebaseFunctionsException) {
      final m = error.message?.trim();
      final hasServerMsg = m != null && m.isNotEmpty;
      switch (error.code) {
        case 'resource-exhausted':
          if (hasServerMsg) return m;
          return isArabic
              ? 'طلبات كثيرة على المساعد. انتظر دقيقة وحاول مرة ثانية.'
              : 'Too many assistant requests. Wait a minute and try again.';
        case 'unavailable':
          return isArabic
              ? 'الخدمة مشغولة أو غير متاحة حالياً. جرّب بعد قليل.'
              : 'The assistant is temporarily unavailable. Please try again shortly.';
        case 'not-found':
          return isArabic
              ? 'تعذّر الاتصال بالمساعد (قد يحتاج التطبيق أو الخادم تحديثاً). جرّب لاحقاً أو استخدم البحث العادي.'
              : 'Could not reach the assistant (app or server may need an update). Try later or use search.';
        case 'unauthenticated':
          return isArabic ? 'انتهت الجلسة. سجّل دخولك مرة ثانية ثم حاول.' : 'Session expired. Sign in again and try.';
        case 'permission-denied':
          return isArabic ? 'ما عندك صلاحية لهذا الإجراء.' : 'You don\'t have permission for this action.';
        case 'invalid-argument':
          return isArabic
              ? 'ما قدرت أفهم الطلب. صغّر الرسالة أو أعد صياغتها وحاول مرة ثانية.'
              : 'Could not process the request. Shorten or rephrase your message and try again.';
        case 'internal':
        case 'internal-error':
          return isArabic ? 'صار خطأ بالخادم. جرّب بعد شوي.' : 'Something went wrong on our side. Please try again soon.';
        default:
          return isArabic
              ? 'تعذّر تنفيذ الطلب. جرّب مرة ثانية.'
              : 'Could not complete the request. Please try again.';
      }
    }
    if (error is TimeoutException) {
      return isArabic
          ? 'انتهى وقت الانتظار. تحقق من النت وجرب مرة ثانية.'
          : 'The request timed out. Check your network and try again.';
    }
    final s = error.toString();
    if (s.contains('404') || s.contains('not-found')) {
      return isArabic
          ? 'تعذّر الاتصال بالمساعد. تأكد من النت أو حدّث التطبيق، أو استخدم البحث العادي.'
          : 'Could not reach the assistant. Check your network or update the app, or use search.';
    }
    if (s.contains('Invalid callable response')) {
      return isArabic
          ? 'رد غير متوقع من الخادم. جرّب مرة ثانية.'
          : 'Unexpected response from the server. Please try again.';
    }
    return isArabic
        ? 'حصل خطأ. تحقق من النت وجرب مرة ثانية، أو استخدم البحث العادي.'
        : 'Something went wrong. Check your network and try again, or use search.';
  }

  static void _logCallableFailure(String callableName, Object e) {
    if (e is FirebaseFunctionsException) {
      debugPrint('[AiBrainService] $callableName FirebaseFunctionsException code=${e.code} message=${e.message}');
    } else if (e is TimeoutException) {
      debugPrint('[AiBrainService] $callableName TimeoutException');
    } else {
      debugPrint('[AiBrainService] $callableName $e');
    }
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data == null) {
      throw Exception('Invalid callable response');
    }
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw Exception('Invalid callable response');
  }

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
    final last8 = chatHistory.length > 8 ? chatHistory.sublist(chatHistory.length - 8) : chatHistory;
    final result = await analyze(
      message: message,
      last8Messages: last8,
      currentFilters: currentFilters ?? {},
      top3LastResults: top3LastResults,
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
    String locale = 'ar',
  }) async {
    try {
      final callable = _callable('aqaraiAgentAnalyze');
      final res = await callable
          .call(<String, dynamic>{
            'message': message,
            'last8Messages': last8Messages,
            'currentFilters': currentFilters,
            'top3LastResults': top3LastResults,
            'locale': locale,
          })
          .timeout(const Duration(seconds: 30));
      return AgentAnalyzeResult.fromJson(_asMap(res.data));
    } on FirebaseFunctionsException catch (e) {
      _logCallableFailure('aqaraiAgentAnalyze', e);
      rethrow;
    } on TimeoutException catch (e) {
      _logCallableFailure('aqaraiAgentAnalyze', e);
      rethrow;
    }
  }

  /// Rank property results by score (area match, nearby, featured, recency, budget).
  /// Returns top 3 only; does not modify Firestore. Use before compose when you have many results.
  Future<List<Map<String, dynamic>>> rankResults({
    required List<Map<String, dynamic>> properties,
    required String requestedAreaCode,
    List<String> nearbyAreaCodes = const [],
    double? userBudget,
  }) async {
    if (properties.isEmpty) return [];
    try {
      final callable = _callable('aqaraiAgentRankResults');
      final res = await callable
          .call(<String, dynamic>{
            'properties': properties,
            'requestedAreaCode': requestedAreaCode,
            'nearbyAreaCodes': nearbyAreaCodes,
            'userBudget': userBudget,
          })
          .timeout(const Duration(seconds: 15));
      final data = _asMap(res.data);
      final top3 = data['top3'] as List<dynamic>?;
      if (top3 == null) return [];
      return top3.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on FirebaseFunctionsException catch (e) {
      _logCallableFailure('aqaraiAgentRankResults', e);
      rethrow;
    } on TimeoutException catch (e) {
      _logCallableFailure('aqaraiAgentRankResults', e);
      rethrow;
    }
  }

  /// When main + nearby both return 0, get similar property recommendations from backend.
  /// Returns reply text and list of recommendation maps (id, areaAr, areaEn, type, price, size).
  Future<Map<String, dynamic>> findSimilarRecommendations({
    required String requestedAreaCode,
    required String propertyType,
    List<String> nearbyAreaCodes = const [],
    double? userBudget,
  }) async {
    try {
      final callable = _callable('aqaraiAgentFindSimilar');
      final res = await callable
          .call(<String, dynamic>{
            'requestedAreaCode': requestedAreaCode,
            'propertyType': propertyType,
            'nearbyAreaCodes': nearbyAreaCodes,
            'userBudget': userBudget,
            'locale': 'ar',
          })
          .timeout(const Duration(seconds: 15));
      final data = _asMap(res.data);
      final reply = data['reply']?.toString() ?? '';
      final recs = data['recommendations'] as List<dynamic>?;
      final recommendations =
          recs != null ? recs.map((e) => Map<String, dynamic>.from(e as Map)).toList() : <Map<String, dynamic>>[];
      return {'reply': reply, 'recommendations': recommendations};
    } on FirebaseFunctionsException catch (e) {
      _logCallableFailure('aqaraiAgentFindSimilar', e);
      rethrow;
    } on TimeoutException catch (e) {
      _logCallableFailure('aqaraiAgentFindSimilar', e);
      rethrow;
    }
  }

  /// Generate marketing-style reply from top 3 results (Kuwaiti tone, one next question).
  /// When [userAskedForMore] is true and there is only one result, backend returns
  /// a message offering to search nearby areas instead of repeating the property.
  /// [rawMessage] is the user's last message, used for buyer intent (investment vs residential).
  /// Pass [currentFilters] and [last8Messages] for personalized ranking (budget / area from chat).
  /// NOTE: the `top_demand_chalets` intent is deprecated on the chat surface —
  /// the AI always serves the user's own specs. Any stale caller that passes
  /// that intent falls through to the standard customer-matched compose path.
  Future<ComposeMarketingOutput> composeMarketingReply({
    required List<Map<String, dynamic>> top3Results,
    bool isAr = true,
    bool userAskedForMore = false,
    bool isNearbyFallback = false,
    String requestedAreaLabel = '',
    String rawMessage = '',
    String? intent,
    Map<String, dynamic>? currentFilters,
    List<Map<String, String>>? last8Messages,
  }) async {
    try {
      final callable = _callable('aqaraiAgentCompose');
      final payload = <String, dynamic>{
        'top3Results': top3Results,
        'locale': isAr ? 'ar' : 'en',
        'userAskedForMore': userAskedForMore,
        'isNearbyFallback': isNearbyFallback,
        'requestedAreaLabel': requestedAreaLabel,
        if (rawMessage.isNotEmpty) 'rawMessage': rawMessage,
        if (intent != null && intent.isNotEmpty) 'intent': intent,
        if (currentFilters != null && currentFilters.isNotEmpty) 'currentFilters': currentFilters,
        if (last8Messages != null && last8Messages.isNotEmpty) 'last8Messages': last8Messages,
      };
      final res = await callable.call(payload).timeout(const Duration(seconds: 25));
      final data = _asMap(res.data);
      final reply = (data['reply'] ?? '').toString().trim();
      final resultsRaw = data['results'];
      final results = resultsRaw is List
          ? resultsRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];
      return ComposeMarketingOutput(reply: reply, results: results);
    } on FirebaseFunctionsException catch (e) {
      _logCallableFailure('aqaraiAgentCompose', e);
      rethrow;
    } on TimeoutException catch (e) {
      _logCallableFailure('aqaraiAgentCompose', e);
      rethrow;
    }
  }

  /// Ranks properties (same as [rankResults]) then composes the marketing reply (same as
  /// [composeMarketingReply]) in one HTTPS call. Use when both steps run back-to-back.
  Future<AgentRankAndComposeResult> rankAndComposeMarketingReply({
    required List<Map<String, dynamic>> properties,
    required String requestedAreaCode,
    List<String> nearbyAreaCodes = const [],
    double? userBudget,
    bool isAr = true,
    bool userAskedForMore = false,
    bool isNearbyFallback = false,
    String requestedAreaLabel = '',
    String rawMessage = '',
    String? preferListingIdFirst,
  }) async {
    if (properties.isEmpty) {
      throw ArgumentError.value(
        properties,
        'properties',
        'rankAndComposeMarketingReply requires non-empty properties',
      );
    }
    try {
      final callable = _callable('aqaraiAgentRankAndCompose');
      final payload = <String, dynamic>{
        'properties': properties,
        'requestedAreaCode': requestedAreaCode,
        'nearbyAreaCodes': nearbyAreaCodes,
        'userBudget': userBudget,
        'locale': isAr ? 'ar' : 'en',
        'userAskedForMore': userAskedForMore,
        'isNearbyFallback': isNearbyFallback,
        'requestedAreaLabel': requestedAreaLabel,
        if (rawMessage.isNotEmpty) 'rawMessage': rawMessage,
        if (preferListingIdFirst != null && preferListingIdFirst.isNotEmpty)
          'preferListingIdFirst': preferListingIdFirst,
      };
      final res = await callable.call(payload).timeout(const Duration(seconds: 40));
      final data = _asMap(res.data);
      final top3 = data['top3'] as List<dynamic>?;
      final replyRaw = data['reply'];
      final top3List = top3 == null
          ? <Map<String, dynamic>>[]
          : top3.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final reply = replyRaw?.toString().trim() ?? '';
      return AgentRankAndComposeResult(top3: top3List, reply: reply);
    } on FirebaseFunctionsException catch (e) {
      _logCallableFailure('aqaraiAgentRankAndCompose', e);
      rethrow;
    } on TimeoutException catch (e) {
      _logCallableFailure('aqaraiAgentRankAndCompose', e);
      rethrow;
    }
  }

  /// Invokes `generateChatSmartSuggestions` when the chat just produced a thin
  /// result set. Returns `null` on any failure — callers should fall back to
  /// the pre-existing "no results" copy rather than surface a noisy error to
  /// the user.
  ///
  /// Contract mirrors `functions/src/smart_suggestions.ts`:
  ///   - `filters` is the Flutter-side filter map (same keys the chat already
  ///     passes to `aqaraiAgentAnalyze`, plus the Date Intelligence triple).
  ///   - `candidatePropertyIds` is the *post-discoverability, pre-rank* pool
  ///     the chat just fetched. It is the pool the server's availability probe
  ///     is allowed to read against — cap of 200 applies.
  ///   - `nearbyAreaCodes` is the client-curated neighbor list (the server
  ///     does not own an area graph).
  ///
  /// Returns decoded JSON including: `triggered`, `failureReason`,
  /// `alternatives[]`, `banner_ar`, `banner_en`.
  Future<Map<String, dynamic>?> generateChatSmartSuggestions({
    required Map<String, dynamic> filters,
    required int originalResultCount,
    List<String> candidatePropertyIds = const [],
    List<String> nearbyAreaCodes = const [],
  }) async {
    try {
      final callable = _callable('generateChatSmartSuggestions');
      final payload = <String, dynamic>{
        'filters': filters,
        'originalResultCount': originalResultCount,
        'candidatePropertyIds': candidatePropertyIds,
        'nearbyAreaCodes': nearbyAreaCodes,
      };
      final res = await callable
          .call(payload)
          .timeout(const Duration(seconds: 15));
      return _asMap(res.data);
    } catch (e) {
      _logCallableFailure('generateChatSmartSuggestions', e);
      return null;
    }
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
