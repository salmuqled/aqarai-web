import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? auctionReadDateTime(dynamic v) {
  if (v is Timestamp) return v.toDate();
  return null;
}

double auctionReadDouble(dynamic v, [double fallback = 0]) {
  if (v is num && v.isFinite) return v.toDouble();
  return fallback;
}

String auctionReadString(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  return v.toString();
}

bool auctionReadBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  return fallback;
}
