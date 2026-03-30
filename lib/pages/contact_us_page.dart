import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/support_ticket.dart';
import 'package:aqarai_app/services/support_ticket_service.dart';

/// Contact / feedback form → `support_tickets` in Firestore.
class ContactUsPage extends StatefulWidget {
  const ContactUsPage({super.key});

  @override
  State<ContactUsPage> createState() => _ContactUsPageState();
}

class _ContactUsPageState extends State<ContactUsPage> {
  final _subjectCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  String _category = SupportTicketCategory.general;
  bool _submitting = false;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  String _categoryLabel(AppLocalizations loc, String key) {
    switch (key) {
      case SupportTicketCategory.general:
        return loc.supportCategoryGeneral;
      case SupportTicketCategory.bug:
        return loc.supportCategoryBug;
      case SupportTicketCategory.propertyInquiry:
        return loc.supportCategoryPropertyInquiry;
      case SupportTicketCategory.payment:
        return loc.supportCategoryPayment;
      default:
        return key;
    }
  }

  Future<void> _submit() async {
    final loc = AppLocalizations.of(context)!;
    final subject = _subjectCtrl.text.trim();
    final message = _messageCtrl.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.supportFillRequired)),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await SupportTicketService.submitTicket(
        subject: subject,
        message: message,
        category: _category,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.supportMessageSent)),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${loc.errorLabel}: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.contactUsTitle),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            loc.supportFormIntro,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _subjectCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: loc.supportSubjectLabel,
              hintText: loc.supportSubjectHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _category,
            decoration: InputDecoration(
              labelText: loc.supportCategoryLabel,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final c in SupportTicketCategory.all)
                DropdownMenuItem(
                  value: c,
                  child: Text(_categoryLabel(loc, c)),
                ),
            ],
            onChanged: _submitting
                ? null
                : (v) {
                    if (v != null) setState(() => _category = v);
                  },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _messageCtrl,
            minLines: 6,
            maxLines: 14,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              alignLabelWithHint: true,
              labelText: loc.supportMessageLabel,
              hintText: loc.supportMessageHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _submitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(loc.supportSubmit),
          ),
        ],
      ),
    );
  }
}
