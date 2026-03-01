import 'package:flutter/material.dart';

/// ✅ Root navigator key (Top-level) to be used safely after await (no BuildContext).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
