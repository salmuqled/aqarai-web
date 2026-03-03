/**
 * مساعد عقار أي — استدعاء OpenAI GPT-4o mini
 * يرد باللهجة الكويتية عندما locale = ar
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import OpenAI from "openai";

const SYSTEM_PROMPT_AR = `أنت المساعد الذكي داخل تطبيق عقار أي (AqarAi) في الكويت. المستخدم يكلمك وهو أصلاً داخل التطبيق من شاشة المحادثة هذه.
- مهم: لا تقل أبداً "استخدم التطبيق" أو "روح للتطبيق" أو "شيك على التطبيق" — هو بالفعل يستخدم التطبيق ويتكلم معك منه.
- رد باللهجة العامية الكويتية. كن مختصراً، واضحاً، وودوداً.
- إذا سأل عن أسعار أو مناطق (مثل القادسية، النزهة، بيت 500 متر): اشرح له أنه يقدر يضغط X فوق ويطلع لصفحة البحث، ومن هناك يفلتر حسب المحافظة والمساحة ويشوف الإعلانات الحقيقية. أو قل له "اضغط X للبحث التقليدي واختر الفلاتر حسب المنطقة والمساحة".
- لا تختلق أرقام أو إعلانات؛ وجهه أن يضغط X ويفلتر بنفسه للحصول على النتائج الفعلية، أو يسأل المعلن.
- إذا سأل عن طريقة استخدام ميزة: اشرح له من واجهة التطبيق (مثلاً: من الرئيسية تقدر تدخل عقارات للبيع/للإيجار/شاليهات ثم تفلتر).`;

const SYSTEM_PROMPT_EN = `You are the in-app assistant for AqarAi in Kuwait. The user is already inside the app, chatting with you on this screen.
- Important: Never say "use the app" or "go to the app" or "check the app" — they are already in the app talking to you.
- Reply in a friendly, concise way. If they ask about prices or areas (e.g. Al-Qadisiya, 500 sqm): tell them they can tap X above to go to the main search, then use filters by area and size to see real listings. Do not invent prices or listings; guide them to tap X and use filters for real results. If they ask how to use a feature, explain the UI (e.g. from home they can open For Sale / Rent / Chalets and filter).`;

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
