// lib/widgets/chat_bubble.dart
//
// Reusable ChatGPT-style message bubble. AqarAi primary (#101046) for user,
// light grey for AI. Asymmetric border radius, 75% max width, RTL-friendly.

import 'package:flutter/material.dart';

/// AqarAi brand primary (user bubble background).
const Color _userBubbleColor = Color(0xFF101046);

/// AI bubble background (light grey).
const Color _aiBubbleColor = Color(0xFFF1F1F1);

/// User bubble: tail on bottom-right → small radius there.
const BorderRadius _userBubbleRadius = BorderRadius.only(
  topLeft: Radius.circular(18),
  topRight: Radius.circular(18),
  bottomLeft: Radius.circular(18),
  bottomRight: Radius.circular(4),
);

/// AI bubble: tail on bottom-left → small radius there.
const BorderRadius _aiBubbleRadius = BorderRadius.only(
  topLeft: Radius.circular(18),
  topRight: Radius.circular(18),
  bottomLeft: Radius.circular(4),
  bottomRight: Radius.circular(18),
);

/// ChatGPT-style chat bubble. Use for user (right) and AI (left) messages.
/// Constrains width to 75% of screen; spacing: margin vertical 6, padding h 14, v 10.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    required this.isUser,
  });

  final String message;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = screenWidth * 0.75;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isUser ? _userBubbleColor : _aiBubbleColor,
              borderRadius: isUser ? _userBubbleRadius : _aiBubbleRadius,
            ),
            child: Text(
              message,
              style: TextStyle(
                fontSize: 15,
                height: 1.45,
                color: isUser ? Colors.white : const Color(0xFF1A1A1A),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
