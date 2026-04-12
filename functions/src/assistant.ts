/**
 * مساعد عقار أي — استدعاء OpenAI GPT-4o mini
 * يرد باللهجة الكويتية عندما locale = ar
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import OpenAI from "openai";
import { assertAiRateLimit } from "./aiRateLimit";

const SYSTEM_PROMPT_AR = `أنت المساعد الذكي داخل تطبيق عقار أي (AqarAi) في الكويت. المستخدم يكلمك وهو أصلاً داخل التطبيق من شاشة المحادثة هذه.
- مهم: لا تقل أبداً "استخدم التطبيق" أو "روح للتطبيق" — هو بالفعل داخل التطبيق. رد باللهجة العامية الكويتية، مختصر وودود.
- إذا يبي يبحث عن عقار أو أسعار أو مناطق (القادسية، النزهة، شاليه، إلخ): قل له يضغط X فوق ويطلع لصفحة البحث، ومن هناك يفلتر حسب المحافظة والمساحة ويشوف الإعلانات. لا تختلق أرقام؛ وجهه للفلاتر أو للمعلن.
- إذا يبي يضيف عقار أو ينشر إعلان: قل له يضغط X ويروح للصفحة الرئيسية، ومن القائمة (أو "إعلاناتي") يقدر يضيف إعلان عقار للبيع أو للإيجار أو شاليه أو يضيف طلب "مطلوب".
- إذا سأل عن طريقة استخدام أي ميزة (بحث، إضافة، فلتر، مطلوب): اشرح له خطوات من واجهة التطبيق (الرئيسية، إعلاناتي، الفلاتر، إلخ).
- أي سؤال عام عن العقار أو المناطق أو نصائح: أجب بشكل مختصر ومفيد، ولو يحتاج إعلانات حقيقية وجهه يضغط X ويفلتر.`;

const SYSTEM_PROMPT_EN = `You are the in-app assistant for AqarAi in Kuwait. The user is already in the app on this chat screen.
- Never say "use the app" or "go to the app". Reply in a friendly, concise way.
- To search or see prices/areas: tell them to tap X to go to the main search, then use filters. Do not invent listings or prices.
- To add a property or post a listing: tell them to tap X to go to the home screen, then from the menu (or "My ads") they can add a listing (for sale, rent, chalet) or a "wanted" request.
- For how to use any feature (search, add, filters): explain the steps in the app. For general property questions, answer briefly and point them to tap X and filter when they need real listings.`;

export const aqaraiAssistant = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }
    await assertAiRateLimit(admin.firestore(), request, "assistant_chat");

    const { message, locale } = (request.data as { message?: string; locale?: string }) || {};
    const text = typeof message === "string" ? message.trim() : "";
    if (!text) {
      throw new HttpsError("invalid-argument", "الرسالة مطلوبة");
    }

    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return {
        reply:
          locale === "ar"
            ? "المساعد مو متصل حالياً. اضغط X واستخدم البحث العادي، أو جرب لاحقاً."
            : "Assistant is not configured. Tap X for traditional search or try again later.",
      };
    }

    try {
      const openai = new OpenAI({ apiKey });
      const systemPrompt = locale === "ar" ? SYSTEM_PROMPT_AR : SYSTEM_PROMPT_EN;

      const completion = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: text },
        ],
        max_tokens: 500,
      });

      const reply =
        completion.choices?.[0]?.message?.content?.trim() ||
        (locale === "ar" ? "ما قدرت أرد، جرب مرة ثانية." : "Could not get a reply. Try again.");

      return { reply };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      const stack = err instanceof Error ? err.stack : undefined;
      console.error("OpenAI error:", msg, stack || "");
      if (err && typeof err === "object") {
        const o = err as Record<string, unknown>;
        if ("status" in o) console.error("OpenAI API status:", o.status);
        if ("code" in o) console.error("OpenAI API code:", o.code);
      }
      throw new HttpsError(
        "internal",
        locale === "ar" ? "حصل خطأ من المساعد. جرب لاحقاً." : "Assistant error. Try again later."
      );
    }
  }
);
