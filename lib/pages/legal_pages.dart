import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';

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
            _LegalDocumentBody(document: _LegalDocumentKind.privacy),
            _LegalDocumentBody(document: _LegalDocumentKind.terms),
          ],
        ),
      ),
    );
  }
}

enum _LegalDocumentKind { privacy, terms }

class _LegalDocumentBody extends StatelessWidget {
  const _LegalDocumentBody({required this.document});

  final _LegalDocumentKind document;

  @override
  Widget build(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode;
    final isAr = code == 'ar';
    final sections = switch (document) {
      _LegalDocumentKind.privacy => isAr ? _privacyAr : _privacyEn,
      _LegalDocumentKind.terms => isAr ? _termsAr : _termsEn,
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
      children: [
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
    'قد نجمع: (أ) بيانات الهوية والتواصل مثل الاسم والبريد الإلكتروني ورقم الهاتف؛ (ب) بيانات الحساب والمصادقة عند تسجيل الدخول (مثل تسجيل الدخول عبر Google) بما في ذلك المعرفات التي يقدمها مزود الخدمة؛ (ج) تفضيلات العقارات والإعلانات المحفوظة وبيانات الاستخدام؛ (د) بيانات الموقع عند تفعيل اكتشاف العقارات حسب الموقع، بما في ذلك إحداثيات GPS عند السماح بذلك من إعدادات الجهاز والقانون المعمول به.',
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

// --- Terms of Service ---

const List<_Section> _termsEn = [
  _Section(
    '1. Agreement',
    'These Terms of Service (“Terms”) govern your access to and use of AqarAi. By creating an account or using the app, you agree to these Terms and to our Privacy Policy. If you do not agree, do not use the services.',
  ),
  _Section(
    '2. Eligibility and accounts',
    'You must provide accurate registration information. You are responsible for safeguarding your credentials. Social login (e.g. Google) is subject to the provider’s terms as well. We may suspend or terminate accounts that violate these Terms or applicable law.',
  ),
  _Section(
    '3. Property listings (user-generated content)',
    'You may publish property listings and related media. You represent that you have rights to the content and that information is materially accurate. You grant AqarAi a license to host, display, distribute, and promote your listings within the service. We may remove or moderate content that is illegal, misleading, infringing, or harmful. You remain responsible for compliance with real-estate advertising rules in your jurisdiction.',
  ),
  _Section(
    '4. Auctions and bidding',
    'Where auctions or bidding features are offered, bids you place may be binding according to the auction rules displayed in the app. False bids, manipulation, shill bidding, or abuse may result in suspension, forfeiture of deposits where applicable, and legal action. Fees, deposits, taxes, and transfer procedures (if any) will be disclosed before you commit. AqarAi may facilitate discovery and bidding technology but is not a substitute for formal legal transfer of title unless expressly stated in a separate agreement.',
  ),
  _Section(
    '5. Live video streaming',
    'Live streaming of property auctions or events may require camera and microphone access. You must grant OS permissions when prompted. Streams must not include unlawful content, harassment, hate speech, invasion of privacy, or intellectual property violations. We may terminate streams or accounts for violations. Other participants must follow respectful conduct; recording or redistribution may be restricted by law or by in-app rules.',
  ),
  _Section(
    '6. Payments',
    'Payments processed through third-party gateways are subject to those providers’ terms. You authorize charges you confirm in the app. Disputes regarding card or wallet charges may need to be raised with your bank or the payment provider as well as with us where relevant.',
  ),
  _Section(
    '7. AI assistant',
    'The AI assistant provides general information only. It may be wrong or incomplete. Decisions about purchases, leases, investments, or legal matters should be confirmed with qualified professionals.',
  ),
  _Section(
    '8. Disclaimers',
    'The service is provided “as is” to the extent permitted by law. We do not guarantee uninterrupted or error-free operation. We are not liable for indirect or consequential damages except where liability cannot be excluded by mandatory law.',
  ),
  _Section(
    '9. Changes and termination',
    'We may modify these Terms or discontinue features. We may suspend or terminate access for breach or risk. Provisions that by nature should survive (e.g. liability limits where allowed, intellectual property) will survive termination.',
  ),
  _Section(
    '10. Governing law',
    'Unless mandatory consumer protections require otherwise, these Terms are intended to be interpreted in a manner consistent with the laws of the State of Kuwait, without regard to conflict-of-law rules. Courts of Kuwait may have jurisdiction for disputes arising from use of the service, subject to applicable mandatory rules.',
  ),
  _Section(
    '11. Contact',
    'For questions about these Terms: aqaraiapp@gmail.com',
  ),
];

const List<_Section> _termsAr = [
  _Section(
    '١. الاتفاق',
    'تحكم شروط الاستخدام هذه («الشروط») وصولك إلى تطبيق عقار أي واستخدامك له. بإنشاء حساب أو استخدام التطبيق فإنك توافق على هذه الشروط وعلى سياسة الخصوصية. إذا لم توافق فلا تستخدم الخدمات.',
  ),
  _Section(
    '٢. الأهلية والحسابات',
    'يجب أن تقدم معلومات تسجيل صحيحة. أنت مسؤول عن حماية بيانات الدخول. تسجيل الدخول الاجتماعي (مثل Google) يخضع أيضاً لشروط المزوّد. قد نعلق أو ننهي الحسابات التي تخالف هذه الشروط أو القانون.',
  ),
  _Section(
    '٣. إعلانات العقارات (محتوى المستخدم)',
    'قد تنشر إعلانات عقارات ووسائط مرتبطة. تقر بأنك تملك الحق في المحتوى وأن المعلومات دقيقة في الجوهر. تمنح عقار أي ترخيصاً لاستضافة عرض إعلاناتك والترويج لها ضمن الخدمة. قد نزيل أو نعدّل محتوى غير قانوني أو مضلل أو منتهكاً أو ضارّاً. تبقى مسؤولاً عن الامتثال لقواعد الإعلان العقاري في نطاق اختصاصك.',
  ),
  _Section(
    '٤. المزادات والمزايدة',
    'حيث تُتاح ميزات المزاد أو المزايدة، قد تكون مزايداتك ملزمة وفق قواعد المزاد المعروضة في التطبيق. المزايدات الوهمية أو التلاعب أو المزايدة الصورية أو الإساءة قد تؤدي إلى إيقاف الحساب أو مصادرة عربون حيث ينطبق ذلك، وإجراءات قانونية. تُعرض الرسوم والعربون والضرائب وإجراءات النقل (إن وُجدت) قبل الالتزام. قد يوفّر عقار أي تقنية للاكتشاف والمزايدة دون أن يغني ذلك عن الإجراءات القانونية لنقل الملكية ما لم يُنص على خلاف ذلك في اتفاق منفصل.',
  ),
  _Section(
    '٥. البث المباشر بالفيديو',
    'قد يتطلب بث مزادات العقارات أو الفعاليات مباشرة الوصول إلى الكاميرا والميكروفون. يجب منح أذونات النظام عند الطلب. يجب ألا يتضمن البث محتوى غير قانوني أو مضايقة أو كراهية أو انتهاك خصوصية أو حقوق ملكية. قد نوقف البث أو الحساب عند المخالفة. يلتزم المشاركون بسلوك محترم؛ قد يقيّد القانون أو قواعد التطبيق التسجيل أو إعادة النشر.',
  ),
  _Section(
    '٦. المدفوعات',
    'المدفوعات عبر بوابات خارجية تخضع لشروط تلك الجهات. تفوّض الخصم الذي تؤكده في التطبيق. قد تُرفع نزاعات البطاقة أو المحفظة إلى البنك أو مزوّد الدفع وإلينا حيث ينطبق ذلك.',
  ),
  _Section(
    '٧. المساعد الذكي',
    'المساعد الذكي يقدّم معلومات عامة فقط وقد يكون خاطئاً أو ناقصاً. يجب التحقق من قرارات الشراء أو الإيجار أو الاستثمار أو الأمور القانونية مع مختصين مؤهلين.',
  ),
  _Section(
    '٨. إخلاء المسؤولية',
    'تُقدَّم الخدمة «كما هي» في الحدود التي يسمح بها القانون. لا نضمن تشغيلاً بلا انقطاع أو بلا أخطاء. لا نتحمل الأضرار غير المباشرة أو التبعية إلا حيث يمنع القانون إخلاء المسؤولية.',
  ),
  _Section(
    '٩. التعديل والإنهاء',
    'قد نعدّل الشروط أو نوقف ميزات. قد نعلق أو ننهي الوصول عند المخالفة أو الخطر. تبقى أحكام بطبيعتها مستمرة (مثل حدود المسؤولية حيث يُسمح، الملكية الفكرية) بعد الإنهاء.',
  ),
  _Section(
    '١٠. القانون الواجب التطبيق',
    'ما لم تفرض قواعد إلزامية لحماية المستهلك خلاف ذلك، تُفسَّر هذه الشروط بما يتسق مع قوانين دولة الكويت دون إخلال بقواعد تنازع القوانين. قد تكون محاكم الكويت مختصة بالنزاعات الناشئة عن استخدام الخدمة مع مراعاة القواعد الإلزامية.',
  ),
  _Section(
    '١١. التواصل',
    'للاستفسارات حول شروط الاستخدام: aqaraiapp@gmail.com',
  ),
];
