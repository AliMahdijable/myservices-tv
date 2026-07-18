import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../utils/category_helpers.dart';
import 'channel_card.dart';

class CategorySection extends StatelessWidget {
  final ChannelCategory category;
  final Function(Channel channel, List<Channel> allChannels) onChannelTap;
  final bool isFirstCategory;
  final Set<String> favoriteUrls;
  final IconData? iconOverride;

  const CategorySection({
    super.key,
    required this.category,
    required this.onChannelTap,
    this.isFirstCategory = false,
    this.favoriteUrls = const {},
    this.iconOverride,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: AppColors.redGradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  iconOverride ?? getCategoryIcon(category.name),
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      category.displayName,
                      style: AppFonts.cairo(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      '${category.channels.length} قناة',
                      style: AppFonts.cairo(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                      textDirection: TextDirection.rtl,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${category.channels.length}',
                  style: AppFonts.cairo(
                    fontSize: 14,
                    color: AppColors.accentRedLight,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // A fixed item extent keeps lazy layout predictable for TV D-pad scrolling.
        // clipBehavior: Clip.none allows the focused card to scale outside the rail.
        SizedBox(
          height: 206,
          child: FocusTraversalGroup(
            child: ListView.builder(
              key: PageStorageKey<String>(
                'channel-rail:${category.name}:${category.sortOrder}',
              ),
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              itemExtent: 148,
              scrollCacheExtent: const ScrollCacheExtent.pixels(592),
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
                    autofocus: isFirstCategory && index == 0,
                    isFavorite: favoriteUrls.contains(channel.url),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
