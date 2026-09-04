import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel.dart';
import '../utils/channel_identity.dart';

/// Persists favourites by channel identity rather than stream URL.
///
/// URLs were the original key, but an Xtream live URL carries the container
/// format and the account credentials, so a format change rewrites every one
/// of them and empties the user's favourites. Entries written by earlier
/// versions are still bare URLs; they are matched leniently and rewritten to
/// identity keys the next time the list is saved.
class FavoritesService {
  static const String _key = 'favorite_channel_urls';

  /// The raw stored entries — a mix of identity keys and legacy URLs. Callers
  /// test membership with [isFavorite] rather than comparing directly.
  static Future<Set<String>> getFavoriteKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).toSet();
  }

  /// Whether [channel] appears in [storedKeys], tolerating legacy URL entries.
  static bool isFavorite(Channel channel, Set<String> storedKeys) {
    if (storedKeys.isEmpty) return false;
    if (storedKeys.contains(channelIdentityKey(channel))) return true;
    return storedKeys.any((key) => matchesStoredChannelKey(channel, key));
  }

  /// Favourites resolved against the current playlist, newest first.
  ///
  /// Resolving through [ChannelResolver] means a favourite survives the
  /// provider renumbering a stream or the app changing container format.
  static Future<List<Channel>> getFavoriteChannels(
    List<ChannelCategory> categories,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_key) ?? [];
    if (stored.isEmpty) return [];

    final resolver = ChannelResolver(
      categories.expand((category) => category.channels),
    );

    final channels = <Channel>[];
    final seen = <String>{};
    for (final key in stored.reversed) {
      final channel = resolver.resolveKey(key);
      if (channel == null) continue;
      if (seen.add(channelIdentityKey(channel))) channels.add(channel);
    }
    return channels;
  }

  /// Toggles [channel]. Returns the new state (true = now a favourite).
  static Future<bool> toggleFavorite(Channel channel) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = List<String>.from(prefs.getStringList(_key) ?? []);
    final identity = channelIdentityKey(channel);

    // Remove every entry that refers to this channel, which also clears any
    // legacy URL duplicate left behind by an older version.
    final before = stored.length;
    stored.removeWhere((key) => matchesStoredChannelKey(channel, key));
    final wasFavorite = stored.length != before;

    if (!wasFavorite) stored.add(identity);
    await prefs.setStringList(_key, stored);
    return !wasFavorite;
  }
}
