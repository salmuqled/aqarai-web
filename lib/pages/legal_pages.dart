import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/widgets/terms_content_view.dart';

/// Published privacy policy URL (GitHub Pages).
const _kPrivacyPolicyWebUrl = 'https://salmuqled.github.io/aqarai-privacy/';

Future<void> _openPrivacyPolicyWebsite(BuildContext context) async {
  final loc = AppLocalizations.of(context)!;
  final uri = Uri.parse(_kPrivacyPolicyWebUrl);
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.instagramPostOpenFailed)),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.instagramPostOpenFailed)),
      );
    }
  }
}

/// Privacy Policy & Terms of Service (Arabic / English by app locale).
/// Contact: aqaraiapp@gmail.com — general information only; not legal advice.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(loc.legalScreenTitle),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: loc.legalTabPrivacy),
              Tab(text: loc.legalTabTerms),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _PrivacyPolicyBody(),
            _LegalTermsFromLocalization(),
          ],
        ),
      ),
    );
  }
}

class _LegalTermsFromLocalization extends StatelessWidget {
  const _LegalTermsFromLocalization();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        TermsContentView(
          bodyText: loc.addPropertyTermsDialogBody,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
        ),
      ],
    );
  }
}

class _PrivacyPolicyBody extends StatelessWidget {
  const _PrivacyPolicyBody();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final code = Localizations.localeOf(context).languageCode;
    final isAr = code == 'ar';
    final sections = isAr ? _privacyAr : _privacyEn;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
      children: [
        FilledButton.tonalIcon(
          onPressed: () => _openPrivacyPolicyWebsite(context),
          icon: const Icon(Icons.open_in_new, size: 20),
          label: Text(loc.legalOpenPrivacyPolicyWebsite),
        ),
        const SizedBox(height: 20),
        for (final s in sections) ...[
          SelectableText(
            s.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            s.body,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.5,
                ),
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

class _Section {
  const _Section(this.title, this.body);
  final String title;
  final String body;
}

// --- Privacy Policy ---

const List<_Section> _privacyEn = [
  _Section(
    '1. Introduction',
    'AqarAi (“we”, “us”, “our”) respects your privacy. This Privacy Policy explains how we collect, use, store, and protect personal information when you use our mobile application and related services. By using AqarAi, you acknowledge this Policy. This document is provided for transparency and does not replace independent legal advice.',
  ),
  _Section(
    '2. Information we collect',
    'We may collect: (a) identity and contact data such as your name, email address, and phone number; (b) account and authentication data when you sign in (for example via Google Sign-In), including identifiers provided by the sign-in provider; (c) property preferences, saved listings, and usage data; (d) location data when you enable location-based discovery, including precise GPS coordinates where permitted by your device settings and applicable law.',
  ),
  _Section(
    '3. How we use your information',
    'We use this information to operate and improve the app, authenticate users, show relevant properties and map-based results, communicate with you about your account or listings, prevent fraud and abuse, and comply with legal obligations.',
  ),
  _Section(
    '4. AI assistant (chat) and personalization',
    'If you use the AI real estate assistant, your messages and related context may be processed by automated systems (including third-party AI providers such as Google Gemini or OpenAI GPT) to generate responses. We may store chat history to improve quality, safety, and personalization. Do not submit sensitive data (e.g. national ID, full payment card numbers, or passwords) in chat. AI outputs may be inaccurate and are not professional, financial, or legal advice.',
  ),
  _Section(
    '5. Payments',
    'Payments (credit/debit cards, Apple Pay, Google Pay, or other methods) are typically processed by licensed payment service providers. Card and wallet data are handled according to industry security standards (such as PCI DSS) by those providers. We do not store full card numbers on our servers when processing is delegated to a compliant gateway. Please review the payment provider’s terms and privacy notice at checkout.',
  ),
  _Section(
    '6. Sharing and processors',
    'We may share data with service providers that help us host the app, analyze usage, deliver AI features, process payments, or send notifications. We require appropriate contractual safeguards. We may disclose information if required by law or to protect rights, safety, and security.',
  ),
  _Section(
    '7. Security and retention',
    'We implement technical and organizational measures designed to protect personal data. Retention periods depend on the purpose (e.g. account lifecycle, legal requirements, dispute resolution). When data is no longer needed, we delete or anonymize it where feasible.',
  ),
  _Section(
    '8. Your choices and rights',
    'Depending on applicable law, you may request access, correction, deletion, or restriction of certain processing, or object to processing. You can often control location access and notifications in your device settings. To exercise rights, contact us using the email below.',
  ),
  _Section(
    '9. International transfers',
    'Your data may be processed in countries other than Kuwait where our providers operate. We take steps consistent with applicable requirements when transferring data across borders.',
  ),
  _Section(
    '10. Children',
    'AqarAi is not directed at children under the minimum age required by law in your jurisdiction. We do not knowingly collect personal data from children inappropriately.',
  ),
  _Section(
    '11. Changes',
    'We may update this Privacy Policy from time to time. We will post the revised version in the app and adjust the “last updated” indication where applicable. Continued use after changes constitutes acceptance unless otherwise required by law.',
  ),
  _Section(
    '12. Contact',
    'Questions about this Privacy Policy: aqaraiapp@gmail.com',
  ),
];

const List<_Section> _privacyAr = [
  _Section(
    '١. مقدمة',
    'يحترم تطبيق عقار أي («نحن») خصوصيتك. توضح سياسة الخصوصية هذه كيفية جمع معلوماتك الشخصية واستخدامها وتخزينها وحمايتها عند استخدام التطبيق والخدمات المرتبطة به. باستخدامك عقار أي فإنك تقر باطلاعك على هذه السياسة. هذا النص معلوماتي ولا يغني عن استشارة قانونية مستقلة.',
  ),
  _Section(
    '٢. البيانات التي قد نجمعها',
    'قد نجمع: (أ) بيانات الهوية والتواصل مثل الاسم والبريد الإلكتروني ورقم الهاتف؛ (ب) بيانات الحساب والمصادقة عند تسجيل الدخول (مثل تسجيل الدخول عبر Google) بما في ذلك المعرفات التي يقدمها مزوّد الخدمة؛ (ج) تفضيلات العقارات والإعلانات المحفوظة وبيانات الاستخدام؛ (د) بيانات الموقع عند تفعيل اكتشاف العقارات حسب الموقع، بما في ذلك إحداثيات GPS عند السماح بذلك من إعدادات الجهاز والقانون المعمول به.',
  ),
  _Section(
    '٣. كيف نستخدم المعلومات',
    'نستخدم البيانات لتشغيل التطبيق وتحسينه، والتحقق من المستخدمين، وعرض العقارات والنتائج على الخريطة، والتواصل معك بخصوص حسابك أو إعلاناتك، والحد من الاحتيال وإساءة الاستخدام، والامتثال للالتزامات القانونية.',
  ),
  _Section(
    '٤. المساعد الذكي (المحادثة) والتخصيص',
    'عند استخدام مساعد العقارات الذكي، قد تُعالج رسائلك والسياق المرتبط بها أنظمة آلية (بما في ذلك مزوّدي ذكاء اصطناعي خارجيون مثل Google Gemini أو OpenAI GPT) لتوليد الردود. قد نخزن سجل المحادثة لتحسين الجودة والسلامة والتخصيص. لا تُدخل في المحادثة بيانات حساسة (مثل الرقم المدني أو أرقام البطاقات كاملة أو كلمات المرور). مخرجات الذكاء الاصطناعي قد تكون غير دقيقة ولا تُعد استشارة مهنية أو مالية أو قانونية.',
  ),
  _Section(
    '٥. المدفوعات',
    'تُعالج المدفوعات (بطاقات الائتمان/الخصم، Apple Pay، Google Pay، أو غيرها) عادةً عبر مزوّدي دفع مرخّصين. تُعالج بيانات البطاقة والمحفظ وفق معايير أمنية للقطاع (مثل PCI DSS) لدى هؤلاء المزوّدين. لا نخزّن أرقام البطاقات كاملة على خوادمنا عند التفويض لبوابة دفع متوافقة. يُرجى مراجعة شروط وسياسة خصوصية مزوّد الدفع عند الدفع.',
  ),
  _Section(
    '٦. المشاركة والمعالجون',
    'قد نشارك البيانات مع مزوّدي خدمات يدعمون الاستضافة، التحليل، ميزات الذكاء الاصطناعي، معالجة المدفوعات، أو الإشعارات، مع التزامات تعاقدية مناسبة. قد نكشف معلوماتاً إذا فرض القانون ذلك أو لحماية الحقوق والسلامة والأمن.',
  ),
  _Section(
    '٧. الأمان والاحتفاظ',
    'نطبّق تدابير تقنية وتنظيمية لحماية البيانات الشخصية. تختلف مدة الاحتفاف حسب الغرض (مثل دورة حياة الحساب، الالتزامات القانونية، المنازعات). عند عدم الحاجة للبيانات نحذفها أو نُجهّلها قدر الإمكان.',
  ),
  _Section(
    '٨. خياراتك وحقوقك',
    'بحسب القانون المعمول، قد تطلب الوصول أو التصحيح أو الحذف أو تقييد المعالجة أو الاعتراض على بعض المعالجة. يمكنك غالباً التحكم في أذونات الموقع والإشعارات من إعدادات الجهاز. لممارسة الحقوق تواصل معنا عبر البريد أدناه.',
  ),
  _Section(
    '٩. التحويلات الدولية',
    'قد تُعالج بياناتك في دول غير الكويت حيث تعمل مزوّداتنا. نتخذ خطوات متسقة مع المتطلبات المعمولة عند نقل البيانات عبر الحدود.',
  ),
  _Section(
    '١٠. الأطفال',
    'التطبيق غير موجّه للأطفال دون الحد الأدنى للسن وفق القانون في بلدك. لا نجمع عن قصد بيانات شخصية من الأطفال بشكل غير ملائم.',
  ),
  _Section(
    '١١. التعديلات',
    'قد نحدّث سياسة الخصوصية من وقت لآخر. سننشر النسخة المحدّثة في التطبيق. استمرار الاستخدام بعد التعديل يُعد قبولاً ما لم يفرض القانون غير ذلك.',
  ),
  _Section(
    '١٢. التواصل',
    'للاستفسارات حول سياسة الخصوصية: aqaraiapp@gmail.com',
  ),
];
