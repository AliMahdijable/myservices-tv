import 'package:flutter/material.dart';

IconData getCategoryIcon(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('bein') || lower.contains('بين') || lower.contains('sport')) {
    return Icons.sports_soccer;
  }
  if (lower.contains('kass') || lower.contains('الكاس') || lower.contains('الكأس')) {
    return Icons.sports;
  }
  if (lower.contains('entertainment') || lower.contains('ترفيه')) {
    return Icons.movie;
  }
  if (lower.contains('alwan') || lower.contains('الوان') || lower.contains('ألوان')) {
    return Icons.palette;
  }
  return Icons.live_tv;
}
