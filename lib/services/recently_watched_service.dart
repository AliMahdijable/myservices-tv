import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel.dart';

class RecentlyWatchedService {
  static const String _key = 'recently_watched_channels';
  static const int _max = 20;

  static Future<void> addChannel(Channel channel) async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_key) ?? []);
    list.removeWhere((e) {
      try {
        return (jsonDecode(e) as Map<String, dynamic>)['url'] == channel.url;
      } catch (_) {
        return false;
      }
    });
    list.insert(0, jsonEncode(channel.toJson()));
    if (list.length > _max) list.removeRange(_max, list.length);
    await prefs.setStringList(_key, list);
  }

  static Future<List<Channel>> getChannels() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).map((e) {
      try {
        return Channel.fromJson(jsonDecode(e) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    }).whereType<Channel>().toList();
  }
}
