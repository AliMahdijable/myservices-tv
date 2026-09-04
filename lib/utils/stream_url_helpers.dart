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

/// Returns the live container format (`ts` / `m3u8`) a stream URL uses, or
/// null for provider-specific URL shapes that carry no recognisable extension.
String? liveStreamFormat(String url) {
  try {
    final path = Uri.parse(url).path.toLowerCase();
    if (path.endsWith('.m3u8')) return 'm3u8';
    if (path.endsWith('.ts')) return 'ts';
  } on FormatException {
    // Not a parseable URL — no format to report.
  }
  return null;
}

/// Strips stream URLs out of text destined for the log.
///
/// Xtream stream URLs embed the account's username and password in the path,
/// so mpv's error messages would otherwise write live credentials into logcat.
String redactUrls(Object value) {
  return value.toString().replaceAll(
    RegExp(r'https?://[^\s]+'),
    '[stream-url]',
  );
}
