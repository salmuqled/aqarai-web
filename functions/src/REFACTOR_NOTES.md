# AI Chat Backend Refactor – Import / Contract Notes

## New file structure

- **search_context.ts** – `SearchContext`, `ConversationStage`, `BuyerIntent`, `createEmptySearchContext`, `getSearchContextFromFilters`, `contextToQueryFilters`
- **intent_parser.ts** – `parseUserMessage`, `normalizeArabic`, `normalizeKuwaitiIntent`, `extractAreaFromText`, `detectSearchModifier`, `detectBuyerIntent`, `isGreetingOnly`, `smartGreeting`, `isNewSearchTrigger`; types: `ParsedIntentResult`, `KuwaitiIntentNormalized`
- **kuwait_areas.ts** – `KUWAIT_AREAS` (used by intent_parser)
- **context_updater.ts** – `applyParamsToContext`, `applyModifierToContext`, `mergeContextForTurn` (pure, no Firestore)
- **query_builder.ts** – `buildQueryPlan`, `BuiltQueryPlan`
- **ranking_engine.ts** – `rankPropertyResults`, `computePropertyLabels`, `computeAveragePrice`, `detectBestDeal`, `findSimilarProperties`; types: `PropertyLabelId`, `FindSimilarParams`
- **insight_engine.ts** – `buildInsights`, `getMarketSignal`; type: `InsightBundle`
- **suggestion_engine.ts** – `buildSmartSuggestions`
- **response_composer.ts** – `composeAssistantResponse`; types: `ComposeResponseInput`, `AssistantResponsePayload`
- **agent_brain.ts** – Orchestrator only; exports the same four callable functions.

## Existing imports

- **index.ts** – No change. Still:  
  `export { aqaraiAgentAnalyze, aqaraiAgentCompose, aqaraiAgentRankResults, aqaraiAgentFindSimilar } from "./agent_brain";`
- **Flutter app** – No change. Same HTTP endpoints and response shapes.

## If you were importing from agent_brain before

- **KuwaitiIntentNormalized**, **normalizeKuwaitiIntent** → use `intent_parser.ts`
- **SessionMemory**, **SearchContext** → use `search_context.ts` (only `SearchContext` is the main type now)
- **SuggestionContext**, **buildNextSuggestions** → use `suggestion_engine.buildSmartSuggestions` with the new params shape
- **PropertyLabelId**, **computePropertyLabels**, **FindSimilarParams**, **findSimilarProperties** → use `ranking_engine.ts`
- **normalizeArabic** → use `intent_parser.ts`

## API contract (unchanged)

- **Analyze response:** `intent`, `params_patch`, `reset_filters`, `is_complete`, `clarifying_questions`, optional `greeting_reply`, `requestType`, `features`, `floors`
- **Compose response:** `reply`, `results`
- **Rank response:** `top3`
- **FindSimilar response:** `recommendations`, `reply`

Firestore schema and client-facing payloads are unchanged.
