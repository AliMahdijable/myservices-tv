import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

enum TvKeyboardLanguage { english, arabic }

/// D-pad navigable on-screen keyboard for Android TV.
///
/// English remains the default so existing setup fields continue to open with
/// a Latin keyboard. Callers such as search can explicitly start in Arabic.
class TvKeyboard extends StatefulWidget {
  final String initialText;
  final String fieldLabel;
  final bool obscureText;
  final TvKeyboardLanguage initialLanguage;

  const TvKeyboard({
    super.key,
    this.initialText = '',
    required this.fieldLabel,
    this.obscureText = false,
    this.initialLanguage = TvKeyboardLanguage.english,
  });

  static Future<String?> show(
    BuildContext context, {
    required String fieldLabel,
    String initialText = '',
    bool obscureText = false,
    TvKeyboardLanguage initialLanguage = TvKeyboardLanguage.english,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TvKeyboard(
        fieldLabel: fieldLabel,
        initialText: initialText,
        obscureText: obscureText,
        initialLanguage: initialLanguage,
      ),
    );
  }

  @override
  State<TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<TvKeyboard> {
  late String _text;
  late TvKeyboardLanguage _language;
  bool _shift = false;

  static const List<List<String>> _englishRows = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
    ['.', ':', '/', '@', '_', '-'],
  ];

  static const List<List<String>> _arabicRows = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['ض', 'ص', 'ث', 'ق', 'ف', 'غ', 'ع', 'ه', 'خ', 'ح'],
    ['ش', 'س', 'ي', 'ب', 'ل', 'ا', 'ت', 'ن', 'م', 'ك'],
    ['ئ', 'ء', 'ؤ', 'ر', 'لا', 'ى', 'ة', 'و'],
    ['ز', 'ظ', 'ط', 'ذ', 'د', 'ج'],
  ];

  bool get _isArabic => _language == TvKeyboardLanguage.arabic;
  List<List<String>> get _activeRows => _isArabic ? _arabicRows : _englishRows;

  @override
  void initState() {
    super.initState();
    _text = widget.initialText;
    _language = widget.initialLanguage;
  }

  void _type(String character) {
    final value = !_isArabic && _shift ? character.toUpperCase() : character;
    setState(() => _text += value);
  }

  void _backspace() {
    if (_text.isEmpty) return;
    setState(() => _text = _removeLastTextElement(_text));
  }

  void _toggleLanguage() {
    setState(() {
      _language = _isArabic
          ? TvKeyboardLanguage.english
          : TvKeyboardLanguage.arabic;
      _shift = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final display = widget.obscureText ? '•' * _text.length : _text;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        decoration: BoxDecoration(
          color: AppColors.secondaryDark,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.85),
              blurRadius: 50,
              spreadRadius: 8,
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.fieldLabel,
              style: AppFonts.cairo(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            Semantics(
              label: widget.obscureText ? 'النص مخفي' : 'النص المكتوب',
              value: widget.obscureText ? '' : _text,
              liveRegion: true,
              excludeSemantics: true,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.accentRedLight,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        display.isEmpty ? ' ' : display,
                        style: AppFonts.cairo(
                          color: display.isEmpty
                              ? Colors.white24
                              : Colors.white,
                          fontSize: 16,
                        ),
                        textDirection: _isArabic
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(
                      Icons.edit,
                      color: AppColors.accentRedLight,
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              // Key rows use fixed pixel widths sized for TV/tablet dialogs;
              // scale the whole block down to fit narrower phone screens
              // instead of overflowing. No-op once it already fits.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  children: [
                    for (
                      var rowIndex = 0;
                      rowIndex < _activeRows.length;
                      rowIndex++
                    )
                      _buildCharacterRow(
                        _activeRows[rowIndex],
                        autofocusIndex: rowIndex == 1 ? 0 : -1,
                      ),
                    const SizedBox(height: 4),
                    _buildActionRow(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharacterRow(
    List<String> characters, {
    int autofocusIndex = -1,
  }) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < characters.length; index++)
              _TvKey(
                label: !_isArabic && _shift
                    ? characters[index].toUpperCase()
                    : characters[index],
                onPressed: () => _type(characters[index]),
                autofocus: index == autofocusIndex,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _TvKey(
            label: _isArabic ? 'English' : 'عربي',
            semanticLabel: _isArabic
                ? 'التبديل إلى لوحة إنجليزية'
                : 'التبديل إلى لوحة عربية',
            onPressed: _toggleLanguage,
            width: 88,
            accent: true,
          ),
          if (!_isArabic) ...[
            const SizedBox(width: 4),
            _TvKey(
              label: _shift ? 'ABC' : 'abc',
              semanticLabel: 'تبديل حالة الأحرف الإنجليزية',
              onPressed: () => setState(() => _shift = !_shift),
              width: 70,
              accent: _shift,
            ),
          ],
          const SizedBox(width: 4),
          _TvKey(
            label: _isArabic ? 'مسافة' : 'SPACE',
            semanticLabel: 'مسافة',
            onPressed: () => _type(' '),
            width: _isArabic ? 226 : 164,
          ),
          const SizedBox(width: 4),
          _TvKey(
            label: '⌫',
            semanticLabel: 'حذف الحرف السابق',
            onPressed: _backspace,
            width: 62,
          ),
          const SizedBox(width: 4),
          _TvKey(
            label: _isArabic ? 'تم' : 'DONE',
            semanticLabel: 'إنهاء الكتابة',
            onPressed: () => Navigator.of(context).pop(_text),
            width: 96,
            primary: true,
          ),
        ],
      ),
    );
  }
}

String _removeLastTextElement(String value) {
  final codePoints = value.runes.toList();
  if (codePoints.isEmpty) return value;

  var start = codePoints.length - 1;
  while (start > 0 && _isTextElementExtender(codePoints[start])) {
    start--;
  }

  if (start > 0 &&
      _isRegionalIndicator(codePoints[start]) &&
      _isRegionalIndicator(codePoints[start - 1])) {
    start--;
  }

  while (start > 1 && codePoints[start - 1] == 0x200D) {
    start -= 2;
    while (start > 0 && _isTextElementExtender(codePoints[start])) {
      start--;
    }
  }

  if (start > 0 && codePoints[start] == 0x0A && codePoints[start - 1] == 0x0D) {
    start--;
  }

  return String.fromCharCodes(codePoints.take(start));
}

bool _isRegionalIndicator(int codePoint) {
  return codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF;
}

bool _isTextElementExtender(int codePoint) {
  return (codePoint >= 0x0300 && codePoint <= 0x036F) ||
      (codePoint >= 0x0610 && codePoint <= 0x061A) ||
      (codePoint >= 0x064B && codePoint <= 0x065F) ||
      codePoint == 0x0670 ||
      (codePoint >= 0x06D6 && codePoint <= 0x06ED) ||
      (codePoint >= 0x1AB0 && codePoint <= 0x1AFF) ||
      (codePoint >= 0x1DC0 && codePoint <= 0x1DFF) ||
      (codePoint >= 0x20D0 && codePoint <= 0x20FF) ||
      (codePoint >= 0xFE00 && codePoint <= 0xFE0F) ||
      (codePoint >= 0xFE20 && codePoint <= 0xFE2F) ||
      (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF) ||
      (codePoint >= 0xE0020 && codePoint <= 0xE007F) ||
      (codePoint >= 0xE0100 && codePoint <= 0xE01EF);
}

class _TvKey extends StatelessWidget {
  final String label;
  final String? semanticLabel;
  final VoidCallback onPressed;
  final double width;
  final bool autofocus;
  final bool primary;
  final bool accent;

  const _TvKey({
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.width = 50,
    this.autofocus = false,
    this.primary = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2),
      child: SizedBox(
        width: width,
        height: 48,
        child: Semantics(
          label: semanticLabel ?? label,
          button: true,
          onTap: onPressed,
          excludeSemantics: true,
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
            },
            child: ElevatedButton(
              autofocus: autofocus,
              onPressed: onPressed,
              style: ButtonStyle(
                padding: WidgetStateProperty.all(EdgeInsets.zero),
                shape: WidgetStateProperty.all(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return AppColors.accentRedLight;
                  }
                  if (primary) return AppColors.accentRed;
                  if (accent) {
                    return AppColors.accentRed.withValues(alpha: 0.55);
                  }
                  return AppColors.surfaceDark;
                }),
                foregroundColor: WidgetStateProperty.all(Colors.white),
                overlayColor: WidgetStateProperty.all(
                  Colors.white.withValues(alpha: 0.2),
                ),
                side: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return const BorderSide(color: Colors.white, width: 3);
                  }
                  if (primary) {
                    return const BorderSide(
                      color: AppColors.accentRed,
                      width: 1,
                    );
                  }
                  return BorderSide(
                    color: Colors.white.withValues(alpha: 0.12),
                  );
                }),
                elevation: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused) ? 10 : 2,
                ),
                shadowColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return AppColors.accentRed.withValues(alpha: 0.75);
                  }
                  return Colors.black38;
                }),
              ),
              child: ExcludeSemantics(
                child: Text(
                  label,
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: label.length == 1 ? 16 : 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
