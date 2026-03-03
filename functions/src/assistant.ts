/**
 * مساعد عقار أي — استدعاء OpenAI GPT-4o mini
 * يرد باللهجة الكويتية عندما locale = ar
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import OpenAI from "openai";

const SYSTEM_PROMPT_AR = `أنت مساعد تطبيق عقار أي (AqarAi) في الكويت. مهمتك مساعدة المستخدمين في البحث عن عقارات، شاليهات، أسعار الإيجار والبيع، ومناطق مثل القادسية وغيرها.
- رد دائماً باللهجة العامية الكويتية عندما يكتب المستخدم بالعربي.
- كن مختصراً، واضحاً، وودوداً. لا تطنّب.
- إذا سأل عن أسعار أو مناطق، وجهه أن يستخدم البحث والفلاتر في التطبيق، أو اشرح له كيف يصل للمعلومة.
- لا تختلق أرقام أو إعلانات؛ إن لم تعرف، قل أن يشوف التطبيق أو يسأل المعلن.`;

const SYSTEM_PROMPT_EN = `You are the assistant for AqarAi, a real estate app in Kuwait. Help users with property search, chalets, rental/sale prices, and areas like Al-Qadisiya. Be concise, friendly, and clear. Do not invent listings or prices; direct them to use the app search when needed.`;

export const aqaraiAssistant = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

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
