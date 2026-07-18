import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel.dart';

class FavoritesService {
  static const String _key = 'favorite_channel_urls';

  static Future<Set<String>> getFavoriteUrls() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).toSet();
  }

  static Future<List<Channel>> getFavoriteChannels(
      List<ChannelCategory> categories) async {
    final prefs = await SharedPreferences.getInstance();
    final urlList = prefs.getStringList(_key) ?? [];
    if (urlList.isEmpty) return [];
    final all = categories.expand((c) => c.channels);
    final map = {for (var ch in all) ch.url: ch};
    return urlList.reversed
        .map((url) => map[url])
        .whereType<Channel>()
        .toList();
  }

  // Returns new favorite state (true = now favorited)
  static Future<bool> toggleFavorite(Channel channel) async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_key) ?? []);
    final wasFav = list.contains(channel.url);
    if (wasFav) {
      list.remove(channel.url);
    } else {
      list.add(channel.url);
    }
    await prefs.setStringList(_key, list);
    return !wasFav;
  }
}
