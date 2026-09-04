import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../models/channel.dart';
import '../services/favorites_service.dart';
import '../theme/app_theme.dart';
import '../utils/channel_identity.dart';
import '../theme/layout_metrics.dart';
import '../utils/category_helpers.dart';
import 'channel_card.dart';

class CategorySection extends StatelessWidget {
  final ChannelCategory category;
  final Function(Channel channel, List<Channel> allChannels) onChannelTap;
  final bool isFirstCategory;
  final Set<String> favoriteKeys;
  final IconData? iconOverride;

  /// Identity key of the channel last opened in the player, so the rail can
  /// mark where the user left off. Null before anything has been played.
  final String? playingKey;

  const CategorySection({
    super.key,
    required this.category,
    required this.onChannelTap,
    this.isFirstCategory = false,
    this.favoriteKeys = const {},
    this.iconOverride,
    this.playingKey,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = ChannelCardMetrics.of(context);
    final isWide = screenClassOf(context) == ScreenClass.wide;
    final inset = isWide ? 24.0 : 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(inset, isWide ? 18 : 14, inset, 4),
          child: Row(
            children: [
              // A short accent rule rather than a filled icon tile: it marks
              // the section without competing with the channel logos for
              // attention, and costs one rect instead of a gradient per header.
              Container(
                width: 4,
                height: isWide ? 26 : 22,
                decoration: BoxDecoration(
                  gradient: AppColors.redGradient,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                iconOverride ?? getCategoryIcon(category.name),
                color: AppColors.accentRedLight,
                size: isWide ? 20 : 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  category.displayName,
                  // Provider category names genuinely need two lines —
                  // truncating 'ALWAN SPORT - باقة الوان الرياضية' drops the
                  // Arabic half entirely.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.cairo(
                    fontSize: isWide ? 22 : 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    height: 1.22,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Flexible, not a bare Text: at a large system text scale the
              // count claimed its full intrinsic width and pushed the header
              // past the edge of a small screen. It shrinks before the title
              // does, since the category name is the part worth reading.
              Flexible(
                child: Text(
                  '${category.channels.length} قناة',
                  textDirection: TextDirection.rtl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.cairo(
                    fontSize: isWide ? 13 : 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
        // A fixed item extent keeps lazy layout predictable for TV D-pad scrolling.
        // clipBehavior: Clip.none allows the focused card to scale outside the rail.
        SizedBox(
          height: metrics.railHeight,
          // Deliberately NOT wrapped in a FocusTraversalGroup. Each group keeps
          // its own directional history, so returning to a rail spent the first
          // UP press restoring that state instead of moving focus — the remote
          // read as if it had missed the press, and every second UP was dead.
          child: ListView.builder(
            key: PageStorageKey<String>(
              'channel-rail:${category.name}:${category.sortOrder}',
            ),
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.symmetric(
              horizontal: inset - metrics.gutter,
              vertical: metrics.railVerticalPadding,
            ),
            itemExtent: metrics.itemExtent,
            scrollCacheExtent: ScrollCacheExtent.pixels(metrics.cacheExtent),
            itemCount: category.channels.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = category.channels.indexWhere(
                (channel) => channel.url == key.value,
              );
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final channel = category.channels[index];
              return RepaintBoundary(
                key: ValueKey<String>(channel.url),
                child: ChannelCard(
                  channel: channel,
                  onTap: () => onChannelTap(channel, category.channels),
                  autofocus: isWide && isFirstCategory && index == 0,
                  isFavorite: FavoritesService.isFavorite(
                    channel,
                    favoriteKeys,
                  ),
                  isPlaying:
                      playingKey != null &&
                      channelIdentityKey(channel) == playingKey,
                ),
              );
            },
          ),
        ),
        SizedBox(height: isWide ? 18 : 12),
      ],
    );
  }
}
