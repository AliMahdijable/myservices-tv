import 'package:shared_preferences/shared_preferences.dart';

/// How video should be decoded.
enum DecoderMode {
  /// Let mpv pick the platform's safe hardware decoder, falling back to
  /// software automatically when a stream repeatedly fails to decode.
  auto,

  /// Force hardware decoding. Lowest CPU use, but some boxes cannot handle
  /// HEVC or interlaced MPEG-2 and produce green frames or freezes.
  hardware,

  /// Force software decoding. Costs CPU but plays essentially anything —
  /// the reliable escape hatch on cheap Android TV sticks.
  software,
}

extension DecoderModeInfo on DecoderMode {
  String get label => switch (this) {
    DecoderMode.auto => 'تلقائي',
    DecoderMode.hardware => 'تسريع عتادي',
    DecoderMode.software => 'برمجي',
  };

  String get description => switch (this) {
    DecoderMode.auto =>
      'يستخدم تسريع الجهاز ويتحوّل تلقائياً إلى البرمجي عند تعذّر التشغيل.',
    DecoderMode.hardware =>
      'أقل استهلاكاً للمعالج. قد يفشل مع بعض قنوات HEVC على الأجهزة الضعيفة.',
    DecoderMode.software =>
      'يشغّل كل الترميزات تقريباً، لكنه يستهلك المعالج أكثر.',
  };

  /// The mpv `hwdec` value this mode maps to. `auto-safe` restricts hardware
  /// decoding to combinations mpv considers reliable on the platform.
  String get mpvHwdec => switch (this) {
    DecoderMode.auto => 'auto-safe',
    DecoderMode.hardware => 'auto',
    DecoderMode.software => 'no',
  };
}

/// How much stream is buffered before playback starts.
///
/// This is the direct trade-off between zap speed and resilience: a small
/// buffer starts a channel almost immediately but rebuffers on a jittery link,
/// while a large one absorbs interruptions at the cost of a slower start.
enum BufferProfile {
  /// Fastest channel switching. Best on a solid LAN or fibre connection.
  fast,

  /// Sensible default for most connections.
  balanced,

  /// Absorbs long interruptions. Best on weak Wi-Fi or mobile data.
  stable,
}

extension BufferProfileInfo on BufferProfile {
  String get label => switch (this) {
    BufferProfile.fast => 'سريع',
    BufferProfile.balanced => 'متوازن',
    BufferProfile.stable => 'مستقر',
  };

  String get description => switch (this) {
    BufferProfile.fast => 'تبديل قنوات شبه فوري. مناسب للشبكات القوية.',
    BufferProfile.balanced => 'توازن بين سرعة التبديل ومقاومة التقطيع.',
    BufferProfile.stable =>
      'يخزّن أكثر قبل البدء، فيتحمّل الانقطاعات الطويلة. مناسب للشبكات الضعيفة.',
  };

  /// Seconds of stream mpv keeps ahead of the playback position.
  String get cacheSeconds => switch (this) {
    BufferProfile.fast => '4',
    BufferProfile.balanced => '10',
    BufferProfile.stable => '20',
  };

  /// Seconds mpv waits while filling the cache before it starts playing.
  ///
  /// mpv's own default holds playback until the cache is comfortably full,
  /// which is what makes a channel take seconds to appear. Keeping this small
  /// is the single largest contributor to a snappy zap.
  String get cachePauseWait => switch (this) {
    BufferProfile.fast => '0.4',
    BufferProfile.balanced => '1',
    BufferProfile.stable => '2.5',
  };

  /// Forward cache size handed to mpv's demuxer.
  int get bufferBytes => switch (this) {
    BufferProfile.fast => 8 * 1024 * 1024,
    BufferProfile.balanced => 16 * 1024 * 1024,
    BufferProfile.stable => 32 * 1024 * 1024,
  };
}

/// Persisted player settings, plus the per-server stream format the app has
/// learned actually works.
class PlaybackPreferences {
  static const String _keyDecoder = 'player_decoder_mode';
  static const String _keyBuffer = 'player_buffer_profile';
  static const String _keyFormatPrefix = 'player_stream_format__';

  /// Live container formats, in the order the app prefers them.
  ///
  /// MPEG-TS leads deliberately. An Xtream panel serves `.ts` as one
  /// long-lived connection, while `.m3u8` opens an HLS session and then
  /// re-requests a segment every few seconds. On panels with a concurrent
  /// connection ceiling that extra churn is exactly what triggers the 403s
  /// this app used to retry its way through.
  static const List<String> supportedFormats = ['ts', 'm3u8'];
  static const String defaultFormat = 'ts';

  static DecoderMode _decoderMode = DecoderMode.auto;
  static BufferProfile _bufferProfile = BufferProfile.balanced;

  static DecoderMode get decoderMode => _decoderMode;
  static BufferProfile get bufferProfile => _bufferProfile;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _decoderMode = _readEnum(
      prefs.getString(_keyDecoder),
      DecoderMode.values,
      DecoderMode.auto,
    );
    _bufferProfile = _readEnum(
      prefs.getString(_keyBuffer),
      BufferProfile.values,
      BufferProfile.balanced,
    );
  }

  static Future<void> setDecoderMode(DecoderMode mode) async {
    _decoderMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDecoder, mode.name);
  }

  static Future<void> setBufferProfile(BufferProfile profile) async {
    _bufferProfile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBuffer, profile.name);
  }

  /// The container format to open [serverKey]'s live streams with.
  ///
  /// Returns whatever last played stably on that server, so a provider that
  /// only serves HLS is discovered once rather than costing every channel a
  /// round of visible failures.
  static Future<String> formatForServer(String serverKey) async {
    if (serverKey.isEmpty) return defaultFormat;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('$_keyFormatPrefix$serverKey');
    return supportedFormats.contains(stored) ? stored! : defaultFormat;
  }

  /// Records the format that just played stably on [serverKey].
  static Future<void> rememberFormat(String serverKey, String format) async {
    if (serverKey.isEmpty || !supportedFormats.contains(format)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_keyFormatPrefix$serverKey', format);
  }

  /// Narrows the default format to what the panel says it will serve.
  ///
  /// Xtream's `user_info.allowed_output_formats` is advisory — this app has
  /// seen panels advertise `m3u8` and still refuse it under load — so it is
  /// only used to rule formats *out*, never to override a format that has
  /// already proven itself in [rememberFormat].
  static Future<void> applyAllowedFormats(
    String serverKey,
    List<String> allowed,
  ) async {
    if (serverKey.isEmpty || allowed.isEmpty) return;
    final usable = supportedFormats.where(allowed.contains).toList();
    if (usable.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final key = '$_keyFormatPrefix$serverKey';
    final stored = prefs.getString(key);
    if (stored != null && usable.contains(stored)) return;
    await prefs.setString(key, usable.first);
  }

  static T _readEnum<T extends Enum>(String? name, List<T> values, T orElse) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return orElse;
  }
}
