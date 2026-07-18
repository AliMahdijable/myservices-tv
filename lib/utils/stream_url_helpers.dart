/// Returns the corresponding HLS/MPEG-TS live URL while preserving query
/// parameters and fragments. Unknown URL shapes are returned unchanged.
String alternateLiveStreamUrl(String url) {
  try {
    final uri = Uri.parse(url);
    final lowerPath = uri.path.toLowerCase();

    if (lowerPath.endsWith('.m3u8')) {
      return uri
          .replace(path: '${uri.path.substring(0, uri.path.length - 5)}.ts')
          .toString();
    }
    if (lowerPath.endsWith('.ts')) {
      return uri
          .replace(path: '${uri.path.substring(0, uri.path.length - 3)}.m3u8')
          .toString();
    }
  } on FormatException {
    // Keep unusual provider-specific URLs intact.
  }
  return url;
}
