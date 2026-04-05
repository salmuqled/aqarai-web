import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/firestore.dart';
import 'package:aqarai_app/services/interest_lead_flow_service.dart';
import 'package:aqarai_app/widgets/interested_lead_confirmation_sheet.dart';

/// صفحة تفاصيل طلب مطلوب — للمستخدم (أنا مهتم) أو للأدمن (اعتماد/رفض)
class WantedDetailsPage extends StatelessWidget {
  final String wantedId;
  final bool isAdminView;

  static const String _whatsAppNumber = '96594442242';

  const WantedDetailsPage({
    super.key,
    required this.wantedId,
    this.isAdminView = false,
  });

  String _typeLabel(BuildContext context, String typeEn, AppLocalizations loc) {
    switch (typeEn) {
      case 'apartment':
        return loc.propertyType_apartment;
      case 'house':
        return loc.propertyType_house;
      case 'building':
        return loc.propertyType_building;
      case 'land':
        return loc.propertyType_land;
      case 'industrialLand':
        return loc.propertyType_industrialLand;
      case 'shop':
        return loc.propertyType_shop;
      case 'office':
        return loc.propertyType_office;
      case 'chalet':
        return loc.propertyType_chalet;
      default:
        return typeEn;
    }
  }

  String _fmtDate(Timestamp? ts) {
    if (ts == null) return '-';
    final dt = ts.toDate();
    return '${dt.year}/${dt.month}/${dt.day} – ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'تفاصيل طلب مطلوب' : 'Wanted request details'),
        centerTitle: true,
      ),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: firestore.collection('wanted_requests').doc(wantedId).get(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData || !snap.data!.exists) {
            return Center(
              child: Text(
                isAr ? 'الطلب غير موجود' : 'Request not found',
              ),
            );
          }

          final d = snap.data!.data()!;
          final ownerName = (d['ownerName'] ?? '-').toString();
          final ownerPhone = (d['ownerPhone'] ?? '').toString();
          final govRaw = (d['governorate'] ?? '-').toString();
          final areaRaw = (d['area'] ?? '-').toString();
          final governorate = isAr ? govRaw : (governorateArToEn[govRaw] ?? govRaw);
          final area = isAr ? areaRaw : (areaArToEn[areaRaw] ?? areaRaw);
          final typeEn = (d['type'] ?? d['propertyType'] ?? '').toString();
          final typeLabel = _typeLabel(context, typeEn, loc);
          final description = (d['description'] ?? '-').toString();
          final minP = d['minPrice'];
          final maxP = d['maxPrice'];
          final createdAt = d['createdAt'] as Timestamp?;
          final approved = d['approved'] == true;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _row(loc.valuation_ownerName, ownerName),
                        if (ownerPhone.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _row(loc.valuation_phone, ownerPhone),
                        ],
                        const SizedBox(height: 12),
                        _row(isAr ? 'المحافظة' : 'Governorate', governorate),
                        const SizedBox(height: 12),
                        _row(isAr ? 'المنطقة' : 'Area', area),
                        const SizedBox(height: 12),
                        _row(loc.propertyType, typeLabel),
                        const SizedBox(height: 12),
                        _row(
                          loc.budget,
                          '${minP ?? '-'} – ${maxP ?? '-'} ${isAr ? 'د.ك' : 'KWD'}',
                        ),
                        const SizedBox(height: 12),
                        _row(isAr ? 'الوصف' : 'Description', description),
                        const SizedBox(height: 12),
                        _row(loc.addedOn, _fmtDate(createdAt)),
                        if (approved)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Row(
                              children: [
                                Icon(Icons.check_circle, color: Colors.green[700], size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  isAr ? 'معتمد' : 'Approved',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green[700],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isAdminView && ownerPhone.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final uri = Uri(scheme: 'tel', path: ownerPhone.trim());
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          icon: const Icon(Icons.call, color: Colors.green),
                          label: Text(
                            isAr ? 'اتصال' : 'Call',
                            style: const TextStyle(color: Colors.green),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.green),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final phone = ownerPhone.replaceAll('+', '').trim();
                            if (phone.isEmpty) return;
                            final uri = Uri.parse('https://wa.me/$phone');
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          icon: const Icon(Icons.chat, color: Colors.green),
                          label: const Text(
                            'WhatsApp',
                            style: TextStyle(color: Colors.green),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.green),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (!isAdminView) ...[
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final phone = await showInterestedLeadPhoneSheet(context);
                        if (!context.mounted || phone == null) return;
                        final areaLabel = governorate.isNotEmpty && area != governorate
                            ? '$governorate - $area'
                            : (area.isNotEmpty ? area : governorate);
                        final dealTitle = isAr
                            ? 'طلب مطلوب: $typeLabel — $areaLabel'
                            : 'Wanted: $typeLabel — $areaLabel';
                        final dealPrice = (maxP is num ? maxP : null) ??
                            (minP is num ? minP : null) ??
                            0;
                        await WantedDetailsPage._onInterestedTap(
                          context,
                          phone: phone,
                          wantedId: wantedId,
                          area: area,
                          governorate: governorate,
                          typeLabel: typeLabel,
                          minP: minP,
                          maxP: maxP,
                          isAr: isAr,
                          loc: loc,
                          dealTitle: dealTitle,
                          dealPrice: dealPrice,
                        );
                      },
                      icon: const Icon(Icons.thumb_up, color: Colors.white),
                      label: Text(
                        loc.imInterested,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
                if (isAdminView && !approved) ...[
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: () async {
                              try {
                                await firestore
                                    .collection('wanted_requests')
                                    .doc(wantedId)
                                    .update({'approved': true});
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(isAr ? 'تم الاعتماد' : 'Approved'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                  Navigator.pop(context);
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('$e')),
                                  );
                                }
                              }
                            },
                            icon: const Icon(Icons.verified),
                            label: Text(loc.approve),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF101046),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(isAr ? 'رفض طلب مطلوب' : 'Reject'),
                                  content: Text(
                                    isAr
                                        ? 'هل تريد رفض هذا الطلب؟ سيُحذف من القائمة.'
                                        : 'Reject this request? It will be removed.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: Text(loc.cancel),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: Text(loc.reject),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm != true) return;
                              try {
                                await firestore
                                    .collection('wanted_requests')
                                    .doc(wantedId)
                                    .delete();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(isAr ? 'تم رفض الطلب' : 'Rejected'),
                                      backgroundColor: Colors.orange,
                                    ),
                                  );
                                  Navigator.pop(context);
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('$e')),
                                  );
                                }
                              }
                            },
                            icon: const Icon(Icons.block),
                            label: Text(loc.reject),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Text(value),
        ),
      ],
    );
  }

  static String _buildWantedWhatsAppMessage(
    bool isAr,
    String area,
    String governorate,
    String typeLabel,
    Object? minP,
    Object? maxP,
    AppLocalizations loc,
  ) {
    final areaLabel = governorate.isNotEmpty && area != governorate
        ? '$governorate - $area'
        : area.isNotEmpty
            ? area
            : governorate;
    final minStr = minP != null ? NumberFormat.decimalPattern(isAr ? 'ar' : 'en').format(minP) : '-';
    final maxStr = maxP != null ? NumberFormat.decimalPattern(isAr ? 'ar' : 'en').format(maxP) : '-';
    final budgetStr = '$minStr – $maxStr ${isAr ? 'د.ك' : 'KWD'}';
    if (isAr) {
      return 'السلام عليكم ورحمة الله وبركاته\n\n'
          '📌 اهتمام بإعلان مطلوب (من تطبيق عقاري)\n\n'
          'أنا مهتم بهذا الطلب المطلوب.\n\n'
          'تفاصيل إعلان المطلوب:\n'
          '• نوع العقار: $typeLabel\n'
          '• المنطقة: $areaLabel\n'
          '• الميزانية: $budgetStr';
    } else {
      return 'Assalamu alaikum\n\n'
          '📌 Interest in a WANTED ad (from Aqarai App)\n\n'
          'I\'m interested in this wanted request.\n\n'
          'Wanted ad details:\n'
          '• Type: $typeLabel\n'
          '• Area: $areaLabel\n'
          '• Budget: $budgetStr';
    }
  }

  static Future<void> _onInterestedTap(
    BuildContext context, {
    required String phone,
    required String wantedId,
    required String area,
    required String governorate,
    required String typeLabel,
    required Object? minP,
    required Object? maxP,
    required bool isAr,
    required AppLocalizations loc,
    required String dealTitle,
    required num dealPrice,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await InterestLeadFlowService.saveUserPhone(uid: user.uid, phone: phone);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAr
                  ? 'تعذر حفظ رقم الهاتف. حاول مرة أخرى.'
                  : 'Could not save your phone number. Please try again.',
            ),
          ),
        );
      }
      return;
    }

    try {
      await InterestLeadFlowService.ensureInterestDeal(
        phone: phone,
        propertyId: '',
        propertyTitle: dealTitle,
        propertyPrice: dealPrice,
        serviceTypeRaw: 'sale',
        wantedId: wantedId,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAr
                  ? 'تعذر إتمام الطلب. حاول لاحقاً.'
                  : 'Could not complete your request. Try again later.',
            ),
          ),
        );
      }
      return;
    }

    final message = _buildWantedWhatsAppMessage(
      isAr,
      area,
      governorate,
      typeLabel,
      minP,
      maxP,
      loc,
    );
    final uri = Uri.parse(
      'https://wa.me/$_whatsAppNumber?text=${Uri.encodeComponent(message)}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.noWantedItems)),
      );
    }
  }
}
