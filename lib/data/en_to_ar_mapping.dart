/// English → Arabic mapping for governorates and areas
/// يُستخدم لتحويل القيم الإنجليزية إلى العربية أثناء البحث.
/// IMPORTANT:
/// هذا الملف لا يعتمد على أي ملفات ثانية.
/// كل التحويلات مكتوبة بشكل صريح وواضح.

const Map<String, String> governorateEnToAr = {
  "Capital Governorate": "محافظة العاصمة",
  "Hawalli Governorate": "محافظة حولي",
  "Farwaniya Governorate": "محافظة الفروانية",
  "Ahmadi Governorate": "محافظة الأحمدي",
  "Jahra Governorate": "محافظة الجهراء",
  "Mubarak Al-Kabeer Governorate": "محافظة مبارك الكبير",
};

const Map<String, String> areaEnToAr = {
  // -------------------------------
  // Capital Governorate
  // -------------------------------
  "Al-Qibla - Jibla": "القبلة - جبلة",
  "Al-Murqab": "المرقاب",
  "Al-Sawlihya": "الصالحية",
  "Abdullah Al-Salem": "عبدالله السالم",
  "Sharq": "الشرق",
  "Mubarakiya": "المباركية",
  "Jaber Al-Ahmad": "جابر الاحمد",
  "Dasma": "الدسمة",
  "Daeya": "الدعية",
  "Faiha": "الفيحاء",
  "Nuzha": "النزهة",
  "Rawda": "الروضة",
  "Adailiya": "العديلية",
  "Khaldiya": "الخالدية",
  "Kaifan": "كيفان",
  "Shamiya": "الشامية",
  "Yarmouk": "اليرموك",
  "Mansouriya": "المنصورية",
  "Qadisiya": "القادسية",
  "Qairawan": "القيروان",
  "Qurtuba": "قرطبة",
  "Surra": "السرة",
  "Doha": "الدوحة",
  "Bneid Al-Qar": "بنيد القار",
  "Dasman": "دسمان",
  "Granada": "غرناطة",
  "North West Sulaibikhat": "شمال غرب الصليبخات",
  "Shuwaikh Residential": "الشويخ السكنية",
  "Shuwaikh Industrial": "الشويخ الصناعية",
  "Sulaibikhat": "الصليبيخات",
  "Nahdha": "النهضة",
  "Hessa Al-Mubarak District": "ضاحية حصه المبارك",

  // -------------------------------
  // Hawalli Governorate
  // -------------------------------
  "Hawalli": "حولي",
  "Salmiya": "السالمية",
  "Bidaa": "البدع",
  "Maidan Hawalli": "ميدان حولي",
  "Jabriya": "الجابرية",
  "Rumaithiya": "الرميثية",
  "Mishref": "مشرف",
  "Bayan": "بيان",
  "Salwa": "سلوى",
  "Zahra": "الزهراء",
  "South Surra": "جنوب السرة",
  "Al-Salam": "السلام",
  "Hateen": "حطين",
  "Shuhada": "الشهداء",
  "Al-Siddiq": "الصديق",
  "Shaab Residential": "الشعب السكني",
  "West Mishref - Mubarak Al-Abdullah": "غرب مشرف - مبارك العبدالله",
  "Shaab Marine": "الشعب البحري",

  // -------------------------------
  // Farwaniya Governorate
  // -------------------------------
  "Farwaniya": "الفروانية",
  "Khaitan": "خيطان",
  "Riggae": "الرقعي",
  "Dajeej": "الضجيج",
  "Rai": "الري",
  "Andalous": "الأندلس",
  "Ardiya": "العارضية",
  "Ardiya Industrial": "العارضية الحرفية - الصناعية",
  "Omariya": "العمرية",
  "South New Khaitan": "خيطان الجنوبي الجديدة",
  "Rabya": "الرابية",
  "Rehab": "الرحاب",
  "Sabah Al-Nasser": "صباح الناصر",
  "Ishbiliya": "اشبيلية",
  "Firdous": "الفردوس",
  "Abdullah Al-Mubarak": "عبدالله المبارك - غرب الجليب",
  "Jleeb Al-Shuyoukh - Hassawi": "جليب الشيوخ - الحساوي",
  "South Abdullah Al-Mubarak": "جنوب عبدالله المبارك",
  "West Abdullah Al-Mubarak": "غرب عبدالله المبارك",
  "Farwaniya Stables": "اسطبلات الفروانية",

  // -------------------------------
  // Ahmadi Governorate
  // -------------------------------
  "Sabah Al-Ahmad Marine - Khiran": "صباح الاحمد البحرية - الخيران",
  "Ahmadi": "الاحمدي",
  "Mangaf": "المنقف",
  "Fahaheel": "الفحيحيل",
  "Abu Halifa": "أبو حليفة",
  "Daher": "الظهر",
  "Reqqa": "الرقة",
  "Hadiya": "هدية",
  "Wafra Housing": "الوفرة السكنية",
  "Sabahiya": "الصباحية",
  "Fintas": "الفنطاس",
  "Mahboula": "المهبولة",
  "Eqaila": "العقيلة",
  "Wafra Farms": "مزارع الوفرة",
  "Fahad Al-Ahmad": "فهد الاحمد",
  "Shuaiba Industrial": "الشعيبة الصناعية",
  "Dhubaiya": "الضباعية",
  "Julaia": "الجليعة",
  "Zour": "الزور",
  "Bneider": "بنيدر",
  "Mina Abdullah": "ميناء عبدالله",
  "Nuwaiseeb": "النويصيب",
  "Jaber Al-Ali": "جابر العلي",
  "Ali Sabah Al-Salem - Umm Al-Hayman": "علي صباح السالم - ام الهيمان",
  "Sabah Al-Ahmad Residential": "صباح الأحمد السكنية",
  "Khiran Residential - Inland": "الخيران السكنية - الجانب البري",
  "South Sabah Al-Ahmad": "جنوب صباح الأحمد",
  "Ahmadi Stables": "اسطبلات الاحمدي",

  // -------------------------------
  // Jahra Governorate
  // -------------------------------
  "Jahra": "الجهراء",
  "Naeem": "النعيم",
  "Qasr": "القصر",
  "Waha": "الواحة",
  "Taima": "تيماء",
  "Sulaibiya": "الصليبية",
  "Oyoun": "العيون",
  "Subiya": "الصبية",
  "Jahra Industrial": "الجهراء الصناعية",
  "Naseem": "النسيم",
  "South Naseem": "النسيم الجنوبي",
  "Amghara Industrial": "امغرة الصناعية",
  "Saad Al-Abdullah": "سعد العبدالله",
  "Kabad": "كبد",
  "Mutlaa": "المطلاع",
  "South Saad Al-Abdullah": "جنوب سعد العبدالله",
  "Khusais": "الخويسات",
  "Hejin": "الهجن",
  "Jahra Stables": "اسطبلات الجهراء",
  "Abdali": "العبدلي",
  "Salmi": "السالمي",
  "Naaim": "النعايم",

  // -------------------------------
  // Mubarak Al-Kabeer Governorate
  // -------------------------------
  "Mubarak Al-Kabeer": "مبارك الكبير",
  "Qurain": "القرين",
  "West Abu Fatira Craft Zone - Aswaq Al-Qurain":
      "اسواق القرين - غرب ابوفطيرة الحرفية",
  "Qusour": "القصور",
  "Adan": "العدان",
  "Messila": "المسيلة",
  "Sabah Al-Salem": "صباح السالم",
  "Abu Fatira": "أبو فطيرة",
  "Abu Hasaniya": "أبو الحصانية",
  "Funaitees": "الفنيطيس",
  "Maseila": "المسايل",
  "Sabhan": "صبحان",
};
