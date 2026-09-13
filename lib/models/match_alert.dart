/// The four moments a match can be announced at.
///
/// Names are deliberately short: they become part of an FCM topic name, and a
/// topic is created the first time anyone subscribes to it, so a rename is a
/// migration rather than an edit.
enum MatchAlertType {
  /// Three quarters of an hour out — enough to travel or to find a screen.
  before45('t45', 'قبل ٤٥ دقيقة'),

  /// The quarter-hour warning.
  before15('t15', 'قبل ١٥ دقيقة'),

  /// The whistle.
  kickoff('ko', 'عند البداية'),

  /// The real final whistle, with the real score.
  fullTime('ft', 'النهاية والنتيجة');

  const MatchAlertType(this.code, this.label);

  /// The token used in topic names. Never change one of these in place.
  final String code;

  /// Arabic label, for the settings UI.
  final String label;

  /// The two that are on for a new user.
  ///
  /// A notification a quarter of an hour before, and the result afterwards, is
  /// the most a football app can send before it becomes the thing you turn
  /// off. The other two are there for people who want them.
  static const Set<MatchAlertType> quietDefault = {before15, fullTime};

  static MatchAlertType? fromCode(String code) {
    for (final type in MatchAlertType.values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// The topic carrying [type] for one specific fixture — a bell the user set.
///
/// Topic names must match `[a-zA-Z0-9-_.~%]+`, which these do.
String matchAlertTopic(int fixtureId, MatchAlertType type) =>
    'm${fixtureId}_${type.code}';

/// The topic carrying [type] for every match a club plays.
///
/// This is what makes following a club work at all. A club's next fixture may
/// not exist yet, and the phone may not be opened again before it is played;
/// a durable club topic is resolved by the sender at the moment it sends, so
/// nothing has to happen on the device in between. Turning a club's matches
/// into per-match subscriptions would only ever cover the matches the device
/// had already seen.
String clubAlertTopic(int clubId, MatchAlertType type) =>
    'c${clubId}_${type.code}';

/// The topic a device joins to silence one fixture it would otherwise be told
/// about through a club it follows.
///
/// The sender excludes these subscribers with a negated term in its condition.
/// That operator is not mentioned anywhere in Firebase's topic documentation,
/// so it is treated as unproven: the sender validates it against the live API
/// before it is allowed to send, rather than discovering in production that
/// muted users were notified anyway.
String muteTopic(int fixtureId) => 'mute$fixtureId';

/// Topics are cheap to create and impossible to enumerate, so the names are
/// fixed here and used by both the app and the sender.
const int fcmMaxTopicsPerCondition = 5;
