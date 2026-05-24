import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel.dart';
import 'xtream_service.dart';
import 'm3u_service.dart';

/// Unified service: tries Xtream Codes JSON API first, falls back to M3U.
class ChannelService {
  static Future<List<ChannelCategory>> fetchCategories({
    bool forceRefresh = false,
  }) async {
    try {
      return await XtreamService.fetchCategories(forceRefresh: forceRefresh);
    } catch (_) {
      final channels =
          await M3uService.fetchChannels(forceRefresh: forceRefresh);
      return M3uService.organizeChannels(channels);
    }
  }

  static Future<void> clearCache() async {
    await XtreamService.clearCache();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cached_channels');
    await prefs.remove('cached_channels_time');
  }
}
