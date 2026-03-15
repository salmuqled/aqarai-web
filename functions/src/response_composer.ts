/**
 * Single place that concatenates reply text blocks. Order: main → market → best deal → buyer intent → area suggestion → suggestions.
 */
import type { InsightBundle } from "./insight_engine";

export interface ComposeResponseInput {
  locale: string;
  mainReplyBody: string;
  results: Record<string, unknown>[];
  insights: InsightBundle;
  suggestions: string[];
}

export interface AssistantResponsePayload {
  reply: string;
  results: Record<string, unknown>[];
  suggestions: string[];
}

function appendBlock(reply: string, block: string | undefined): string {
  if (!block || block.trim() === "") return reply;
  if (reply.trim() === "") return block;
  return reply + "\n\n" + block;
}

export function composeAssistantResponse(input: ComposeResponseInput): AssistantResponsePayload {
  const { locale, mainReplyBody, results, insights, suggestions } = input;
  const isAr = locale === "ar";
  let reply = mainReplyBody.trim();

  reply = appendBlock(reply, insights.marketText);
  reply = appendBlock(reply, insights.priceRangeText);
  reply = appendBlock(reply, insights.bestDealText);
  reply = appendBlock(reply, insights.buyerIntentText);
  reply = appendBlock(reply, insights.areaSuggestionText);

  if (suggestions.length > 0) {
    const prefix = isAr ? "ممكن أيضاً:\n\n" : "You can also:\n\n";
    const lines = suggestions.map((s) => `• ${s}`).join("\n");
    reply = appendBlock(reply, prefix + lines);
  }

  return {
    reply: reply.trim(),
    results,
    suggestions,
  };
}
