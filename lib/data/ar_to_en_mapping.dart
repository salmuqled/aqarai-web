// ------------------------------------------------------
// Arabic → English mapping (Governorates + Areas)
// يستخدم لتحويل القيم العربية إلى الإنجليزية
// ------------------------------------------------------

const Map<String, String> governorateArToEn = {
  "محافظة العاصمة": "Capital Governorate",
  "محافظة حولي": "Hawalli Governorate",
  "محافظة الفروانية": "Farwaniya Governorate",
  "محافظة الأحمدي": "Ahmadi Governorate",
  "محافظة الجهراء": "Jahra Governorate",
  "محافظة مبارك الكبير": "Mubarak Al-Kabeer Governorate",
};

const Map<String, String> areaArToEn = {
  // -------------------------------
  // محافظة العاصمة
  // -------------------------------
  "القبلة - جبلة": "Al-Qibla - Jibla",
  "المرقاب": "Al-Murqab",
  "الصالحية": "Al-Sawlihya",
  "عبدالله السالم": "Abdullah Al-Salem",
  "الشرق": "Sharq",
  "المباركية": "Mubarakiya",
  "جابر الاحمد": "Jaber Al-Ahmad",
  "الدسمة": "Dasma",
  "الدعية": "Daeya",
  "الفيحاء": "Faiha",
  "النزهة": "Nuzha",
  "الروضة": "Rawda",
  "العديلية": "Adailiya",
  "الخالدية": "Khaldiya",
  "كيفان": "Kaifan",
  "الشامية": "Shamiya",
  "اليرموك": "Yarmouk",
  "المنصورية": "Mansouriya",
  "القادسية": "Qadisiya",
  "القيروان": "Qairawan",
  "قرطبة": "Qurtuba",
  "السرة": "Surra",
  "الدوحة": "Doha",
  "بنيد القار": "Bneid Al-Qar",
  "دسمان": "Dasman",
  "غرناطة": "Granada",
  "شمال غرب الصليبخات": "North West Sulaibikhat",
  "الشويخ السكنية": "Shuwaikh Residential",
  "الشويخ الصناعية": "Shuwaikh Industrial",
  "الصليبيخات": "Sulaibikhat",
  "النهضة": "Nahdha",
  "ضاحية حصه المبارك": "Hessa Al-Mubarak District",

  // -------------------------------
  // محافظة حولي
  // -------------------------------
  "حولي": "Hawalli",
  "السالمية": "Salmiya",
  "البدع": "Bidaa",
  "ميدان حولي": "Maidan Hawalli",
  "الجابرية": "Jabriya",
  "الرميثية": "Rumaithiya",
  "مشرف": "Mishref",
  "بيان": "Bayan",
  "سلوى": "Salwa",
  "الزهراء": "Zahra",
  "جنوب السرة": "South Surra",
  "السلام": "Al-Salam",
  "حطين": "Hateen",
  "الشهداء": "Shuhada",
  "الصديق": "Al-Siddiq",
  "الشعب السكني": "Shaab Residential",
  "غرب مشرف - مبارك العبدالله": "West Mishref - Mubarak Al-Abdullah",
  "الشعب البحري": "Shaab Marine",

  // -------------------------------
  // محافظة الفروانية
  // -------------------------------
  "الفروانية": "Farwaniya",
  "خيطان": "Khaitan",
  "الرقعي": "Riggae",
  "الضجيج": "Dajeej",
  "الري": "Rai",
  "الأندلس": "Andalous",
  "العارضية": "Ardiya",
  "العارضية الحرفية - الصناعية": "Ardiya Industrial",
  "العمرية": "Omariya",
  "خيطان الجنوبي الجديدة": "South New Khaitan",
  "الرابية": "Rabya",
  "الرحاب": "Rehab",
  "صباح الناصر": "Sabah Al-Nasser",
  "اشبيلية": "Ishbiliya",
  "الفردوس": "Firdous",
  "عبدالله المبارك - غرب الجليب": "Abdullah Al-Mubarak",
  "جليب الشيوخ - الحساوي": "Jleeb Al-Shuyoukh - Hassawi",
  "جنوب عبدالله المبارك": "South Abdullah Al-Mubarak",
  "غرب عبدالله المبارك": "West Abdullah Al-Mubarak",
  "اسطبلات الفروانية": "Farwaniya Stables",

  // -------------------------------
  // محافظة الأحمدي
  // -------------------------------
  "صباح الاحمد البحرية - الخيران": "Sabah Al-Ahmad Marine - Khiran",
  "الاحمدي": "Ahmadi",
  "المنقف": "Mangaf",
  "الفحيحيل": "Fahaheel",
  "أبو حليفة": "Abu Halifa",
  "الظهر": "Daher",
  "الرقة": "Reqqa",
  "هدية": "Hadiya",
  "الوفرة السكنية": "Wafra Housing",
  "الصباحية": "Sabahiya",
  "الفنطاس": "Fintas",
  "المهبولة": "Mahboula",
  "العقيلة": "Eqaila",
  "مزارع الوفرة": "Wafra Farms",
  "فهد الاحمد": "Fahad Al-Ahmad",
  "الشعيبة الصناعية": "Shuaiba Industrial",
  "الضباعية": "Dhubaiya",
  "الجليعة": "Julaia",
  "الزور": "Zour",
  "بنيدر": "Bneider",
  "ميناء عبدالله": "Mina Abdullah",
  "النويصيب": "Nuwaiseeb",
  "جابر العلي": "Jaber Al-Ali",
  "علي صباح السالم - ام الهيمان": "Ali Sabah Al-Salem - Umm Al-Hayman",
  "صباح الأحمد السكنية": "Sabah Al-Ahmad Residential",
  "الخيران السكنية - الجانب البري": "Khiran Residential - Inland",
  "جنوب صباح الأحمد": "South Sabah Al-Ahmad",
  "اسطبلات الاحمدي": "Ahmadi Stables",

  // -------------------------------
  // محافظة الجهراء
  // -------------------------------
  "الجهراء": "Jahra",
  "النعيم": "Naeem",
  "القصر": "Qasr",
  "الواحة": "Waha",
  "تيماء": "Taima",
  "الصليبية": "Sulaibiya",
  "العيون": "Oyoun",
  "الصبية": "Subiya",
  "الجهراء الصناعية": "Jahra Industrial",
  "النسيم": "Naseem",
  "النسيم الجنوبي": "South Naseem",
  "امغرة الصناعية": "Amghara Industrial",
  "سعد العبدالله": "Saad Al-Abdullah",
  "كبد": "Kabad",
  "المطلاع": "Mutlaa",
  "جنوب سعد العبدالله": "South Saad Al-Abdullah",
  "الخويسات": "Khusais",
  "الهجن": "Hejin",
  "اسطبلات الجهراء": "Jahra Stables",
  "العبدلي": "Abdali",
  "السالمي": "Salmi",
  "النعايم": "Naaim",

  // -------------------------------
  // محافظة مبارك الكبير
  // -------------------------------
  "مبارك الكبير": "Mubarak Al-Kabeer",
  "القرين": "Qurain",
  "اسواق القرين - غرب ابوفطيرة الحرفية":
      "West Abu Fatira Craft Zone - Aswaq Al-Qurain",
  "القصور": "Qusour",
  "العدان": "Adan",
  "المسيلة": "Messila",
  "صباح السالم": "Sabah Al-Salem",
  "أبو فطيرة": "Abu Fatira",
  "أبو الحصانية": "Abu Hasaniya",
  "الفنيطيس": "Funaitees",
  "المسايل": "Maseila",
  "صبحان": "Sabhan",
};
