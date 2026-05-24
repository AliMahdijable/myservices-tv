import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../utils/category_helpers.dart';
import 'channel_card.dart';

class CategorySection extends StatelessWidget {
  final ChannelCategory category;
  final Function(Channel channel, List<Channel> allChannels) onChannelTap;
  final bool isFirstCategory;

  const CategorySection({
    super.key,
    required this.category,
    required this.onChannelTap,
    this.isFirstCategory = false,
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
                  getCategoryIcon(category.name),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
        // Horizontal channel slider - using SingleChildScrollView + Row
        // instead of ListView.builder to keep all focus nodes alive for D-pad navigation
        // clipBehavior: Clip.none allows scaled/glowing focused cards to overflow
        SizedBox(
          height: 190,
          child: FocusTraversalGroup(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: List.generate(category.channels.length, (index) {
                  final channel = category.channels[index];
                  return RepaintBoundary(
                    child: ChannelCard(
                      channel: channel,
                      onTap: () => onChannelTap(channel, category.channels),
                      autofocus: isFirstCategory && index == 0,
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
