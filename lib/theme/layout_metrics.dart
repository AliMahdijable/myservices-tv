import 'package:flutter/widgets.dart';

/// Size class for the whole layout.
///
/// One threshold, applied everywhere, so a TV and a phone never disagree about
/// what "a card" is. 600dp shortest side is the same line the setup screen
/// already draws between the on-screen keyboard and the system one.
enum ScreenClass { phone, wide }

ScreenClass screenClassOf(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= 600
    ? ScreenClass.wide
    : ScreenClass.phone;

/// Every dimension of a channel card and its rail.
///
/// Kept in one object rather than scattered across widgets because the card,
/// its rail's `itemExtent` and the rail's height must agree exactly: the rail
/// is a lazy list with a fixed extent, so a card that disagrees with it either
/// clips or leaves a gap.
@immutable
class ChannelCardMetrics {
  /// Resting card width. The focused card grows from this.
  final double width;

  /// The square logo stage at the top of the card.
  final double stage;

  /// The name plate below it.
  final double plateHeight;

  /// The inner plate a logo is centred on.
  final double logoPlate;

  final double radius;

  /// Horizontal margin on each side of a card.
  final double gutter;

  final double nameSize;
  final double groupSize;
  final double badgeSize;

  const ChannelCardMetrics._({
    required this.width,
    required this.stage,
    required this.plateHeight,
    required this.logoPlate,
    required this.radius,
    required this.gutter,
    required this.nameSize,
    required this.groupSize,
    required this.badgeSize,
  });

  /// How much a focused card grows. Large enough to break the rhythm of a row
  /// of identical tiles from across a room — the old 1.06 did not.
  static const double focusScale = 1.10;

  /// How far a focused card lifts, in logical pixels.
  static const double focusLift = 4;

  static const ChannelCardMetrics wide = ChannelCardMetrics._(
    width: 176,
    stage: 176,
    plateHeight: 68,
    logoPlate: 124,
    radius: 20,
    gutter: 10,
    nameSize: 15,
    groupSize: 12,
    badgeSize: 10,
  );

  static const ChannelCardMetrics phone = ChannelCardMetrics._(
    width: 152,
    stage: 152,
    plateHeight: 60,
    logoPlate: 106,
    radius: 18,
    gutter: 8,
    nameSize: 13.5,
    groupSize: 11,
    badgeSize: 9,
  );

  static ChannelCardMetrics of(BuildContext context) =>
      screenClassOf(context) == ScreenClass.wide ? wide : phone;

  double get height => stage + plateHeight;

  /// The rail's fixed item extent. Must equal the card's full footprint.
  double get itemExtent => width + gutter * 2;

  /// Vertical padding inside the rail.
  ///
  /// A focused card scales about its centre, so it grows UPWARD by half the
  /// gain as well as downward, and then lifts further up on top of that.
  /// Without room for both, the focused card climbs over the section header
  /// above it — which is exactly what a rail of tiles must never do, since the
  /// header says which category the user is in.
  double get railVerticalPadding =>
      height * (focusScale - 1) / 2 + focusLift + 6;

  /// Rail height, sized to contain a focused card without clipping it.
  ///
  /// The rail sets `clipBehavior: Clip.none` so growth can overflow visually,
  /// but the row still has to reserve the room or the focused card collides
  /// with whatever sits beneath it.
  double get railHeight => height + railVerticalPadding * 2;

  /// Pixels of rail to keep built ahead of the viewport — three cards.
  double get cacheExtent => itemExtent * 3;
}
