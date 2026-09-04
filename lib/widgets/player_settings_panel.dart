import 'package:flutter/material.dart';

import '../player/playback_preferences.dart';
import '../theme/app_theme.dart';

/// One tunable row: a label, the available values, and which one is selected.
class PlayerSettingRow {
  final IconData icon;
  final String title;
  final List<String> optionLabels;
  final String description;
  final int selectedIndex;

  const PlayerSettingRow({
    required this.icon,
    required this.title,
    required this.optionLabels,
    required this.description,
    required this.selectedIndex,
  });
}

/// Playback settings shown over the video, driven entirely by the remote.
///
/// Decoder and buffer choices live here rather than in the setup screen
/// because they are diagnosed while watching: a channel breaks up, and the fix
/// is two presses away instead of a trip out of playback and back.
class PlayerSettingsPanel extends StatelessWidget {
  final List<PlayerSettingRow> rows;

  /// Row the D-pad is currently on. Key handling lives in the player screen,
  /// alongside the rest of the remote-control logic.
  final int focusedRow;

  /// Selects (rowIndex, optionIndex) by touch. The panel is driven by the
  /// D-pad on a TV, but the same build ships to iOS and to Android phones
  /// where a remote does not exist — without this the decoder and buffer
  /// controls, which are the ones a user reaches for when a stream is
  /// breaking up, could not be operated at all.
  final void Function(int rowIndex, int optionIndex) onSelect;

  const PlayerSettingsPanel({
    super.key,
    required this.rows,
    required this.focusedRow,
    required this.onSelect,
  });

  /// The rows the player screen renders, built from current preferences.
  static List<PlayerSettingRow> rowsFor({required int aspectMode}) {
    return [
      PlayerSettingRow(
        icon: Icons.memory_rounded,
        title: 'فك الترميز',
        optionLabels: DecoderMode.values.map((m) => m.label).toList(),
        description: PlaybackPreferences.decoderMode.description,
        selectedIndex: PlaybackPreferences.decoderMode.index,
      ),
      PlayerSettingRow(
        icon: Icons.speed_rounded,
        title: 'التخزين المؤقت',
        optionLabels: BufferProfile.values.map((p) => p.label).toList(),
        description: PlaybackPreferences.bufferProfile.description,
        selectedIndex: PlaybackPreferences.bufferProfile.index,
      ),
      PlayerSettingRow(
        icon: Icons.aspect_ratio_rounded,
        title: 'نسبة العرض',
        optionLabels: const ['ملاءمة', 'ملء'],
        description: aspectMode == 0
            ? 'يعرض الصورة كاملة مع أشرطة سوداء عند اختلاف النسبة.'
            : 'يملأ الشاشة بالكامل مع اقتصاص أطراف الصورة.',
        selectedIndex: aspectMode,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // The panel is sized for a TV but the same build runs on phones held in
    // landscape, where a fixed 380 would crowd the video and clip its own
    // chips.
    final width = MediaQuery.sizeOf(context).width * 0.55;
    return Positioned(
      right: 24,
      top: 20,
      bottom: 20,
      width: width.clamp(300.0, 380.0),
      // Swallows taps that land on the panel's own background. The player
      // wraps the whole Stack in a GestureDetector that toggles the OSD, so
      // without this any touch on the panel would dismiss it.
      child: GestureDetector(
        onTap: () {},
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.primaryDark.withValues(alpha: 0.96),
              border: Border.all(
                color: AppColors.accentRed.withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: rows.length,
                    itemBuilder: (_, index) =>
                        _buildRow(rows[index], index, index == focusedRow),
                  ),
                ),
                _buildHint(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.tune_rounded, color: AppColors.accentRed, size: 20),
          const SizedBox(width: 8),
          Text(
            'إعدادات التشغيل',
            style: AppFonts.cairo(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(PlayerSettingRow row, int rowIndex, bool isFocused) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isFocused
            ? AppColors.accentRed.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isFocused ? AppColors.accentRed : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                row.icon,
                size: 18,
                color: isFocused ? Colors.white : Colors.white60,
              ),
              const SizedBox(width: 8),
              Text(
                row.title,
                style: AppFonts.cairo(
                  color: isFocused ? Colors.white : Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Wrap, not Row: option labels are free Arabic text of varying width
          // ('تسريع عتادي' is more than twice 'برمجي'), so a fixed row clipped
          // the last chip — the one the user most often needs — off the panel.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < row.optionLabels.length; i++)
                _buildChip(
                  row.optionLabels[i],
                  selected: i == row.selectedIndex,
                  rowFocused: isFocused,
                  onTap: () => onSelect(rowIndex, i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            row.description,
            style: AppFonts.cairo(
              color: Colors.white38,
              fontSize: 11,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(
    String label, {
    required bool selected,
    required bool rowFocused,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      // The chips are small targets; opaque hit testing keeps the padding
      // tappable rather than only the glyphs.
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: selected ? AppColors.redGradient : null,
          color: selected ? null : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected && rowFocused
                ? Colors.white.withValues(alpha: 0.6)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: AppFonts.cairo(
            color: selected ? Colors.white : Colors.white54,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildHint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Text(
        'المس الخيار لاختياره — أو الأسهم ← → للتغيير و↑ ↓ للتنقّل',
        style: AppFonts.cairo(color: Colors.white38, fontSize: 11),
        textAlign: TextAlign.center,
      ),
    );
  }
}
