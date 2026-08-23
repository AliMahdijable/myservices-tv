import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/channel.dart';
import '../models/fixture.dart';
import '../services/fixtures_service.dart';
import '../theme/app_theme.dart';
import '../widgets/focusable_icon_button.dart';
import 'player_screen.dart';

class FixturesScreen extends StatefulWidget {
  final List<ChannelCategory> categories;

  const FixturesScreen({super.key, required this.categories});

  @override
  State<FixturesScreen> createState() => _FixturesScreenState();
}

enum _LoadState { loading, notConfigured, error, loaded }

class _FixturesScreenState extends State<FixturesScreen> {
  _LoadState _state = _LoadState.loading;
  List<Fixture> _fixtures = const [];
  String? _errorMessage;
  bool _openingPlayer = false;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final refreshInPlace = forceRefresh && _fixtures.isNotEmpty;
    setState(() {
      if (refreshInPlace) {
        _isRefreshing = true;
      } else {
        _state = _LoadState.loading;
      }
    });
    try {
      final fixtures = await FixturesService.fetchTodayFixtures(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _fixtures = fixtures;
        _state = _LoadState.loaded;
        _isRefreshing = false;
      });
    } on FixturesNotConfiguredException {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.notConfigured;
        _isRefreshing = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (refreshInPlace) {
        setState(() => _isRefreshing = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'تعذّر تحديث جدول المباريات',
                textAlign: TextAlign.center,
                style: AppFonts.cairo(color: Colors.white, fontSize: 14),
              ),
              backgroundColor: AppColors.surfaceDark,
              behavior: SnackBarBehavior.floating,
            ),
          );
      } else {
        setState(() {
          _errorMessage = 'تعذّر تحميل جدول المباريات';
          _state = _LoadState.error;
          _isRefreshing = false;
        });
      }
    }
  }

  void _openPlayer(Channel channel) {
    if (_openingPlayer) return;
    _openingPlayer = true;
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) =>
                PlayerScreen(channel: channel, categories: widget.categories),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
            transitionDuration: const Duration(milliseconds: 200),
          ),
        )
        .then((_) => _openingPlayer = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              _buildBar(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          FocusableIconButton(
            icon: Icons.arrow_back_rounded,
            semanticLabel: 'رجوع',
            autofocus: true,
            iconSize: 22,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'جدول المباريات',
              style: AppFonts.cairo(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
              textDirection: TextDirection.rtl,
            ),
          ),
          FocusableIconButton(
            icon: Icons.refresh_rounded,
            semanticLabel: 'تحديث الجدول',
            isLoading: _isRefreshing,
            iconSize: 22,
            onTap: (_state == _LoadState.loading || _isRefreshing)
                ? null
                : () => _load(forceRefresh: true),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _LoadState.loading:
        return const Center(
          child: CircularProgressIndicator(color: AppColors.accentRed),
        );
      case _LoadState.notConfigured:
        return _buildMessage(
          icon: Icons.sports_soccer_rounded,
          title: 'جدول المباريات غير مفعّل',
          body:
              'يحتاج هذا القسم مفتاح API مجاني من api-football.com لعرض '
              'مباريات اليوم.',
          showRetry: false,
        );
      case _LoadState.error:
        return _buildMessage(
          icon: Icons.wifi_off_rounded,
          title: _errorMessage ?? 'حدث خطأ',
          body: 'تحقّق من اتصالك بالإنترنت وحاول مجدداً.',
          showRetry: true,
        );
      case _LoadState.loaded:
        return _buildFixturesList();
    }
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String body,
    required bool showRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceDark.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, color: AppColors.textMuted, size: 52),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            if (showRetry) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                autofocus: true,
                onPressed: () => _load(forceRefresh: true),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  'إعادة المحاولة',
                  style: AppFonts.cairo(fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentRed,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 13,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFixturesList() {
    if (_fixtures.isEmpty) {
      return _buildMessage(
        icon: Icons.event_busy_rounded,
        title: 'لا توجد مباريات اليوم',
        body: 'راجع الجدول لاحقاً.',
        showRetry: false,
      );
    }

    final live = _fixtures.where((f) => f.isLive).toList();
    final upcoming = _fixtures.where((f) => f.isUpcoming).toList();
    final finished = _fixtures.where((f) => f.isFinished).toList();

    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (widget.categories.isEmpty) _buildChannelsNotLoadedHint(),
          if (live.isNotEmpty) _buildSection('مباشر الآن', live),
          if (upcoming.isNotEmpty) _buildSection('مباريات قادمة', upcoming),
          if (finished.isNotEmpty)
            _buildSection('انتهت', finished, muted: true),
        ],
      ),
    );
  }

  Widget _buildChannelsNotLoadedHint() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: AppColors.textMuted,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'لم تُحمَّل قنواتك بعد، فلن تظهر أزرار "شاهد" حتى تحميلها',
              style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 12),
              textDirection: TextDirection.rtl,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
    String title,
    List<Fixture> fixtures, {
    bool muted = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            title,
            style: AppFonts.cairo(
              color: muted ? AppColors.textMuted : AppColors.accentRedLight,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
            textDirection: TextDirection.rtl,
          ),
        ),
        for (final fixture in fixtures)
          _FixtureRow(
            key: ValueKey<int>(fixture.id),
            fixture: fixture,
            channel: FixturesService.suggestChannel(fixture, widget.categories),
            muted: muted,
            onWatch: _openPlayer,
          ),
      ],
    );
  }
}

class _FixtureRow extends StatefulWidget {
  final Fixture fixture;
  final Channel? channel;
  final bool muted;
  final ValueChanged<Channel> onWatch;

  const _FixtureRow({
    super.key,
    required this.fixture,
    required this.channel,
    required this.muted,
    required this.onWatch,
  });

  @override
  State<_FixtureRow> createState() => _FixtureRowState();
}

class _FixtureRowState extends State<_FixtureRow> {
  bool _isFocused = false;

  String get _timeLabel {
    final kickoff = widget.fixture.kickoff;
    final hour = kickoff.hour.toString().padLeft(2, '0');
    final minute = kickoff.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Widget _buildScoreOrTime() {
    final fixture = widget.fixture;
    if (fixture.isUpcoming) {
      return Text(
        _timeLabel,
        style: AppFonts.cairo(
          color: Colors.white70,
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
      );
    }
    final home = fixture.homeGoals ?? 0;
    final away = fixture.awayGoals ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$home - $away',
          style: AppFonts.cairo(
            color: fixture.isLive ? AppColors.accentRedLight : Colors.white70,
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (fixture.isLive)
          Text(
            fixture.elapsedMinutes != null
                ? "'${fixture.elapsedMinutes}"
                : 'مباشر',
            style: AppFonts.cairo(
              color: AppColors.accentRedLight,
              fontSize: 10,
            ),
          ),
      ],
    );
  }

  Widget _buildTeam(String name, String logoUrl) {
    return Expanded(
      child: Column(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: logoUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: logoUrl,
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) => const Icon(
                      Icons.shield_outlined,
                      color: Colors.white38,
                      size: 20,
                    ),
                  )
                : const Icon(
                    Icons.shield_outlined,
                    color: Colors.white38,
                    size: 20,
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.cairo(
              color: widget.muted ? Colors.white38 : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fixture = widget.fixture;
    final channel = widget.channel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceDark.withValues(
            alpha: widget.muted ? 0.4 : 0.7,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                _buildTeam(fixture.homeTeam, fixture.homeLogoUrl),
                SizedBox(width: 64, child: _buildScoreOrTime()),
                _buildTeam(fixture.awayTeam, fixture.awayLogoUrl),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    fixture.league,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.cairo(
                      color: AppColors.textMuted,
                      fontSize: 11,
                    ),
                    textDirection: TextDirection.rtl,
                  ),
                ),
                if (channel != null) ...[
                  const SizedBox(width: 8),
                  _WatchButton(
                    isFocused: _isFocused,
                    onFocusChange: (f) => setState(() => _isFocused = f),
                    onTap: () => widget.onWatch(channel),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WatchButton extends StatelessWidget {
  final bool isFocused;
  final ValueChanged<bool> onFocusChange;
  final VoidCallback onTap;

  const _WatchButton({
    required this.isFocused,
    required this.onFocusChange,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'شاهد على القناة المقترحة',
      child: Focus(
        onFocusChange: onFocusChange,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              gradient: AppColors.redGradient,
              borderRadius: BorderRadius.circular(10),
              border: isFocused
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 14,
                ),
                const SizedBox(width: 3),
                Text(
                  'شاهد',
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
