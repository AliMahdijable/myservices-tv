import '../models/channel.dart';

/// Stable identity for a channel across playlist refreshes.
///
/// The stream URL is deliberately the *last* resort. An Xtream live URL embeds
/// the container format (`.../1.ts` vs `.../1.m3u8`) and the account
/// credentials, so any change to either — a format the app learned works, a
/// password rotation — rewrites the URL of every channel. Keying saved data on
/// it means favourites silently empty out on an upgrade that touches neither.
String channelIdentityKey(Channel channel) {
  if (channel.streamId > 0) return 'stream:${channel.streamId}';

  final tvgId = channel.tvgId.trim().toLowerCase();
  if (tvgId.isNotEmpty) return 'tvg:$tvgId';

  final name = channel.name.trim().toLowerCase();
  if (name.isNotEmpty) {
    return 'name:$name\u0000${channel.group.trim().toLowerCase()}';
  }

  return 'url:${normalizeStreamUrl(channel.url)}';
}

/// Strips the live container extension from a stream URL.
///
/// Lets a URL saved as `.m3u8` still match the same channel now built as
/// `.ts`, which is what makes the migration below possible without asking the
/// user to rebuild their favourites.
String normalizeStreamUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  try {
    final uri = Uri.parse(trimmed);
    final path = uri.path;
    final lower = path.toLowerCase();
    for (final extension in const ['.m3u8', '.ts']) {
      if (lower.endsWith(extension)) {
        return uri
            .replace(path: path.substring(0, path.length - extension.length))
            .toString()
            .toLowerCase();
      }
    }
    return trimmed.toLowerCase();
  } on FormatException {
    return trimmed.toLowerCase();
  }
}

/// Whether [channel] is the one a stored entry refers to.
///
/// Accepts both current identity keys and the raw stream URLs written by
/// earlier versions, so saved data survives the upgrade.
bool matchesStoredChannelKey(Channel channel, String storedKey) {
  if (storedKey.isEmpty) return false;
  if (storedKey == channelIdentityKey(channel)) return true;

  // Legacy entry: a bare stream URL. Compare with the container extension
  // removed so a `.m3u8` favourite still matches the `.ts` build of it.
  if (!storedKey.contains(':') || storedKey.startsWith('http')) {
    return normalizeStreamUrl(storedKey) == normalizeStreamUrl(channel.url);
  }
  return false;
}

/// Resolves channels saved in an earlier session against the current playlist.
///
/// Falls through progressively weaker identities so a channel survives a
/// provider renumbering a stream, dropping an EPG id, or moving it between
/// categories — losing an entry is worse than occasionally matching a rename.
class ChannelResolver {
  final Map<String, Channel> _byIdentity = {};
  final Map<String, Channel> _byNormalizedUrl = {};
  final Map<int, Channel> _byStreamId = {};
  final Map<String, Channel> _byTvgId = {};
  final Map<String, Channel> _byNameAndGroup = {};

  ChannelResolver(Iterable<Channel> channels) {
    for (final channel in channels) {
      _byIdentity.putIfAbsent(channelIdentityKey(channel), () => channel);
      _byNormalizedUrl.putIfAbsent(
        normalizeStreamUrl(channel.url),
        () => channel,
      );
      if (channel.streamId > 0) {
        _byStreamId.putIfAbsent(channel.streamId, () => channel);
      }
      final tvgId = channel.tvgId.trim().toLowerCase();
      if (tvgId.isNotEmpty) _byTvgId.putIfAbsent(tvgId, () => channel);
      _byNameAndGroup.putIfAbsent(_nameGroupKey(channel), () => channel);
    }
  }

  /// Resolves a stored key (identity key or legacy URL) to a live channel.
  Channel? resolveKey(String storedKey) {
    if (storedKey.isEmpty) return null;
    final direct = _byIdentity[storedKey];
    if (direct != null) return direct;
    return _byNormalizedUrl[normalizeStreamUrl(storedKey)];
  }

  /// Resolves a deserialized channel to its current equivalent.
  Channel? resolveChannel(Channel stored) {
    final byUrl = _byNormalizedUrl[normalizeStreamUrl(stored.url)];
    if (byUrl != null) return byUrl;

    if (stored.streamId > 0) {
      final byStreamId = _byStreamId[stored.streamId];
      if (byStreamId != null) return byStreamId;
    }

    final tvgId = stored.tvgId.trim().toLowerCase();
    if (tvgId.isNotEmpty) {
      final byTvgId = _byTvgId[tvgId];
      if (byTvgId != null) return byTvgId;
    }

    return _byNameAndGroup[_nameGroupKey(stored)];
  }

  static String _nameGroupKey(Channel channel) =>
      '${channel.name.trim().toLowerCase()}\u0000'
      '${channel.group.trim().toLowerCase()}';
}
