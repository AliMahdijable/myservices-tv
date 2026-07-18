class Channel {
  final String name;
  final String url;
  final String logoUrl;
  final String group;
  final String tvgId;
  final String tvgName;
  final int streamId;
  final Map<String, String> httpHeaders;

  Channel({
    required this.name,
    required this.url,
    this.logoUrl = '',
    this.group = '',
    this.tvgId = '',
    this.tvgName = '',
    this.streamId = 0,
    Map<String, String> httpHeaders = const {},
  }) : httpHeaders = Map.unmodifiable(httpHeaders);

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'logoUrl': logoUrl,
    'group': group,
    'tvgId': tvgId,
    'tvgName': tvgName,
    'streamId': streamId,
    'httpHeaders': httpHeaders,
  };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
    name: json['name'] ?? '',
    url: json['url'] ?? '',
    logoUrl: json['logoUrl'] ?? '',
    group: json['group'] ?? '',
    tvgId: json['tvgId'] ?? '',
    tvgName: json['tvgName'] ?? '',
    streamId: (json['streamId'] as num?)?.toInt() ?? 0,
    httpHeaders: _headersFromJson(json['httpHeaders']),
  );

  static Map<String, String> _headersFromJson(dynamic value) {
    if (value is! Map) return const {};

    final headers = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is String && entry.value is String) {
        headers[entry.key as String] = entry.value as String;
      }
    }
    return headers;
  }

  @override
  String toString() =>
      'Channel(name: $name, group: $group, streamId: $streamId)';
}

class ChannelCategory {
  final String name;
  final String displayName;
  final List<Channel> channels;
  final int sortOrder;

  ChannelCategory({
    required this.name,
    required this.displayName,
    required this.channels,
    required this.sortOrder,
  });
}
