import 'package:cloud_firestore/cloud_firestore.dart';

/// 🔹 Instance موحّد لـ Firestore
/// نستخدمه في كل الصفحات (add_property, my_ads, admin, valuation…)
final FirebaseFirestore firestore = FirebaseFirestore.instance;
