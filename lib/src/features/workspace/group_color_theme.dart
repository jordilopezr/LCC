import 'package:flutter/material.dart';
import 'workspace_group.dart';

/// Theme-aware color for a group. Used for the header chip (full color) and,
/// at low opacity, the segment background.
Color groupColor(GroupColor c, ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  switch (c) {
    case GroupColor.blue:
      return dark ? const Color(0xFF4C8DFF) : const Color(0xFF2F6FB0);
    case GroupColor.purple:
      return dark ? const Color(0xFFB877D6) : const Color(0xFFA34BA3);
    case GroupColor.green:
      return dark ? const Color(0xFF4FB06A) : const Color(0xFF3B8D52);
    case GroupColor.amber:
      return dark ? const Color(0xFFE0A23B) : const Color(0xFFB37F1E);
    case GroupColor.red:
      return dark ? const Color(0xFFE06A70) : const Color(0xFFC0444B);
    case GroupColor.grey:
      return dark ? const Color(0xFF9AA0A6) : const Color(0xFF6A737D);
  }
}
