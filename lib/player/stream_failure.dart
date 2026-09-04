/// Classification of a playback failure, derived from mpv/FFmpeg log text.
///
/// Knowing *why* a stream failed decides how to recover. Retrying a 401 five
/// times cannot succeed, and — more importantly on Xtream panels — every retry
/// holds a server-side connection slot open. Blind retries against a server
/// that is already refusing connections are what push it further past its
/// limit, so the recovery delay is derived from the kind of failure.
library;

enum StreamFailureKind {
  /// The device itself has no usable network. Retrying is pointless until
  /// connectivity returns, so the controller waits for a connectivity event
  /// instead of burning attempts.
  offline,

  /// HTTP 403. On Xtream Codes panels this almost always means the account's
  /// concurrent-connection ceiling is reached, not that the channel is
  /// forbidden — the same URL succeeds again once slots free up. Recovery has
  /// to back off long enough for the server to release them.
  serverBusy,

  /// HTTP 401 — credentials rejected or subscription expired. No amount of
  /// retrying fixes this; the user has to re-enter their details.
  unauthorized,

  /// HTTP 404 — this stream id no longer exists on the panel. The playlist is
  /// stale; other channels may still work.
  notFound,

  /// HTTP 5xx — the panel is broken or overloaded. Worth retrying, slowly.
  serverError,

  /// DNS failure, refused connection or timeout: the host could not be
  /// reached at all.
  unreachable,

  /// The stream opened but playback broke down — decoder error, or a stall the
  /// watchdog caught. Often recoverable by reopening, and may indicate the
  /// hardware decoder cannot handle this stream.
  playback,

  /// Nothing in the message identified the cause.
  unknown,
}

extension StreamFailureKindInfo on StreamFailureKind {
  /// Whether reopening the same stream could plausibly succeed.
  bool get isRetryable => switch (this) {
    StreamFailureKind.unauthorized => false,
    StreamFailureKind.notFound => false,
    _ => true,
  };

  /// Whether this failure suggests the hardware decoder is at fault, making a
  /// software-decoding retry worthwhile.
  bool get suggestsDecoderFallback => this == StreamFailureKind.playback;

  /// Whether trying the provider's other container format (.m3u8 ↔ .ts) is
  /// sensible. A busy or unreachable server refuses both formats equally, so
  /// switching only doubles the connection churn without improving the odds.
  bool get suggestsAlternateFormat => switch (this) {
    StreamFailureKind.notFound ||
    StreamFailureKind.playback ||
    StreamFailureKind.unknown => true,
    _ => false,
  };

  /// User-facing Arabic headline for the terminal error overlay.
  String get title => switch (this) {
    StreamFailureKind.offline => 'لا يوجد اتصال بالإنترنت',
    StreamFailureKind.serverBusy => 'السيرفر مشغول حالياً',
    StreamFailureKind.unauthorized => 'بيانات الاشتراك مرفوضة',
    StreamFailureKind.notFound => 'القناة لم تعد متوفرة',
    StreamFailureKind.serverError => 'خطأ في السيرفر',
    StreamFailureKind.unreachable => 'تعذّر الوصول إلى السيرفر',
    StreamFailureKind.playback => 'تعذّر تشغيل هذا البث',
    StreamFailureKind.unknown => 'تعذّر تشغيل القناة',
  };

  /// Actionable Arabic explanation shown under the headline.
  String get guidance => switch (this) {
    StreamFailureKind.offline => 'تحقّق من الواي‑فاي أو الشبكة، وسيُستأنف '
        'التشغيل تلقائياً عند عودة الاتصال.',
    StreamFailureKind.serverBusy =>
      'تم بلوغ الحد الأقصى للاتصالات المتزامنة على حسابك. أغلق الأجهزة الأخرى '
          'التي تشاهد عليها، ثم أعد المحاولة بعد قليل.',
    StreamFailureKind.unauthorized =>
      'اسم المستخدم أو كلمة المرور غير صحيحة، أو انتهى اشتراكك. راجع الإعدادات.',
    StreamFailureKind.notFound =>
      'حُذفت هذه القناة من السيرفر أو تغيّر رقمها. جرّب تحديث قائمة القنوات.',
    StreamFailureKind.serverError =>
      'السيرفر يواجه مشكلة مؤقتة. جرّب قناة أخرى أو أعد المحاولة لاحقاً.',
    StreamFailureKind.unreachable =>
      'تأكّد من صحة عنوان السيرفر ومن أنك على الشبكة الصحيحة.',
    StreamFailureKind.playback =>
      'قد لا يدعم جهازك ترميز هذا البث. جرّب تبديل وضع فك الترميز من الإعدادات.',
    StreamFailureKind.unknown =>
      'تعذّر تشغيل هذه القناة. جرّب قناة أخرى أو أعد المحاولة.',
  };
}

/// mpv log lines that reach the error stream without playback having stopped.
///
/// media_kit forwards every mpv message at its internal 'error' severity, which
/// sits *below* mpv's own 'fatal' level. Several of these are routine on live
/// streams, and treating them as failures tears down a session that is playing
/// perfectly well — the most expensive kind of false positive, since the
/// reconnect it triggers costs the user a visible stall and the server a
/// connection slot.
bool isBenignStreamLog(String message) {
  final text = message.toLowerCase();

  // mpv probes seekability and duration on every open, unrelated to any user
  // action — this player exposes no seek UI at all. The probe fails harmlessly
  // on live feeds while playback continues. Confirmed against media_kit's
  // MPV_EVENT_LOG_MESSAGE handling in real.dart.
  if (text.contains('cannot seek in this stream')) return true;

  // No usable audio output: silent video, not stopped video. Common on
  // simulators, headless devices and boxes with HDMI audio negotiation
  // trouble, where reconnecting can never restore the missing device.
  if (text.contains('could not open/initialize audio device') ||
      text.contains('no sound') ||
      text.contains('audio device underrun')) {
    return true;
  }

  return false;
}

/// Extracts the failure kind from an mpv/FFmpeg log line.
///
/// media_kit forwards mpv's log messages verbatim, and FFmpeg's HTTP layer
/// reports the status code in the text (`Server returned 403 Forbidden`).
/// Reading it here means the cause is known for free — issuing a separate
/// probe request would itself consume one of the connection slots that are
/// scarce precisely when this matters most.
StreamFailureKind classifyStreamFailure(String message) {
  final text = message.toLowerCase();

  // FFmpeg's HTTP status reports. Matched before the generic patterns below
  // because a 403 body can also mention "failed to open".
  if (_mentionsStatus(text, 401) ||
      text.contains('unauthorized') ||
      text.contains('authentication failed')) {
    return StreamFailureKind.unauthorized;
  }
  if (_mentionsStatus(text, 403) || text.contains('forbidden')) {
    return StreamFailureKind.serverBusy;
  }
  if (_mentionsStatus(text, 404) || text.contains('not found')) {
    return StreamFailureKind.notFound;
  }
  if (text.contains('5xx server error') ||
      _mentionsStatus(text, 500) ||
      _mentionsStatus(text, 502) ||
      _mentionsStatus(text, 503) ||
      _mentionsStatus(text, 504)) {
    return StreamFailureKind.serverError;
  }

  if (text.contains('failed to resolve') ||
      text.contains('name or service not known') ||
      text.contains('temporary failure in name resolution')) {
    return StreamFailureKind.unreachable;
  }
  if (text.contains('network is unreachable') ||
      text.contains('no route to host')) {
    return StreamFailureKind.offline;
  }
  if (text.contains('connection refused') ||
      text.contains('connection timed out') ||
      text.contains('connection reset') ||
      text.contains('operation timed out') ||
      text.contains('ffurl_open failed') ||
      text.contains('tcp: ') ||
      text.contains('i/o error')) {
    return StreamFailureKind.unreachable;
  }

  // Decoder-level breakdowns: mpv prefixes these with vd/ad/vo and FFmpeg
  // reports codec failures. These are the cases a software-decoding retry can
  // actually rescue.
  if (text.contains('could not open codec') ||
      text.contains('decoder init failed') ||
      text.contains('failed to initialize a decoder') ||
      text.contains('hardware decoding') ||
      text.contains('no decoder found') ||
      text.contains('unsupported codec') ||
      text.contains('mediacodec') ||
      text.startsWith('vd:') ||
      text.startsWith('ad:') ||
      text.startsWith('vo:')) {
    return StreamFailureKind.playback;
  }

  if (text.contains('failed to open') ||
      text.contains('failed to recognize file format') ||
      text.contains('invalid data found')) {
    return StreamFailureKind.playback;
  }

  return StreamFailureKind.unknown;
}

/// Matches an HTTP status code as a standalone number so that a code embedded
/// in an unrelated token (a stream id, a byte offset) is not mistaken for one.
bool _mentionsStatus(String text, int code) {
  final pattern = RegExp('(?<![0-9])$code(?![0-9])');
  if (!pattern.hasMatch(text)) return false;
  // FFmpeg always frames the code with one of these words; requiring one
  // avoids matching a channel named "404" or a URL path segment.
  return text.contains('server returned') ||
      text.contains('http error') ||
      text.contains('status') ||
      text.contains('error $code') ||
      text.contains('code $code');
}
