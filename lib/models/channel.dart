class Channel {
  final String name;
  final String url;
  final String logoUrl;
  final String group;
  final String tvgId;
  final String tvgName;
  final int streamId;

  Channel({
    required this.name,
    required this.url,
    this.logoUrl = '',
    this.group = '',
    this.tvgId = '',
    this.tvgName = '',
    this.streamId = 0,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'logoUrl': logoUrl,
        'group': group,
        'tvgId': tvgId,
        'tvgName': tvgName,
        'streamId': streamId,
      };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        name: json['name'] ?? '',
        url: json['url'] ?? '',
        logoUrl: json['logoUrl'] ?? '',
        group: json['group'] ?? '',
        tvgId: json['tvgId'] ?? '',
        tvgName: json['tvgName'] ?? '',
        streamId: (json['streamId'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'Channel(name: $name, group: $group, streamId: $streamId)';
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
