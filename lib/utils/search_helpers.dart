import '../models/channel.dart';

const int maxVisibleSearchResults = 120;

/// Normalizes Arabic text so visually equivalent searches produce the same
/// result. Whitespace is collapsed rather than removed to keep word boundaries.
String normalizeSearchText(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u06D6-\u06ED]'), '')
      .replaceAll('\u0640', '')
      .replaceAll(RegExp(r'[\u0622\u0623\u0625\u0671]'), '\u0627')
      .replaceAll('\u0649', '\u064a')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class ChannelSearchResults {
  final List<Channel> channels;
  final int total;

  const ChannelSearchResults({required this.channels, required this.total});
}

class ChannelSearchIndex {
  final List<_IndexedChannel> _entries;

  ChannelSearchIndex(Iterable<Channel> channels)
    : _entries = _buildEntries(channels);

  List<Channel> get channels =>
      List.unmodifiable(_entries.map((entry) => entry.channel));

  int get length => _entries.length;

  ChannelSearchResults search(
    String query, {
    int limit = maxVisibleSearchResults,
  }) {
    final normalizedQuery = normalizeSearchText(query);
    if (normalizedQuery.isEmpty) {
      return const ChannelSearchResults(channels: [], total: 0);
    }

    final visibleLimit = limit < 0 ? 0 : limit;
    final terms = normalizedQuery.split(' ');
    final matches = <Channel>[];
    var total = 0;
    for (final entry in _entries) {
      if (!terms.every(entry.searchText.contains)) continue;
      total++;
      if (matches.length < visibleLimit) matches.add(entry.channel);
    }

    return ChannelSearchResults(
      channels: List.unmodifiable(matches),
      total: total,
    );
  }

  static List<_IndexedChannel> _buildEntries(Iterable<Channel> channels) {
    final seen = <String>{};
    final entries = <_IndexedChannel>[];

    for (final channel in channels) {
      final key = _channelIdentity(channel);
      if (!seen.add(key)) continue;

      final searchText = [
        channel.name,
        channel.tvgName,
        channel.group,
      ].map(normalizeSearchText).where((value) => value.isNotEmpty).join(' ');

      entries.add(_IndexedChannel(channel, searchText));
    }

    return List.unmodifiable(entries);
  }

  static String _channelIdentity(Channel channel) {
    final url = channel.url.trim();
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        final normalizedUrl = uri
            .replace(
              scheme: uri.scheme.toLowerCase(),
              host: uri.host.toLowerCase(),
            )
            .toString();
        return 'url:$normalizedUrl';
      }
      return 'url:$url';
    }
    if (channel.streamId > 0) return 'stream:${channel.streamId}';

    return 'metadata:${normalizeSearchText(channel.name)}|'
        '${normalizeSearchText(channel.tvgName)}|'
        '${normalizeSearchText(channel.group)}';
  }
}

class _IndexedChannel {
  final Channel channel;
  final String searchText;

  const _IndexedChannel(this.channel, this.searchText);
}
