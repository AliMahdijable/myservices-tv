import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/screens/home_screen.dart';
import 'package:myservices_tv/services/favorites_service.dart';
import 'package:myservices_tv/services/recently_watched_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('preloaded home restores favorites and recently watched', (
    tester,
  ) async {
    const url = 'https://stream.example.test/live/1.m3u8';
    final channel = Channel(
      name: 'قناة الاختبار',
      url: url,
      group: 'اختبار',
      streamId: 1,
    );
    SharedPreferences.setMockInitialValues({
      'favorite_channel_urls': <String>[url],
      'recently_watched_channels': <String>[jsonEncode(channel.toJson())],
    });
    expect(await FavoritesService.getFavoriteUrls(), {url});
    expect(await RecentlyWatchedService.getChannels(), hasLength(1));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: HomeScreen(
          preloadedCategories: [
            ChannelCategory(
              name: 'test',
              displayName: 'اختبار',
              channels: [channel],
              sortOrder: 0,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('شاهدت مؤخراً'), findsOneWidget);
    expect(find.text('المفضلة'), findsOneWidget);
  });
}
