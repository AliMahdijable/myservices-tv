import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/screens/home_screen.dart';
import 'package:myservices_tv/services/fixtures_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The home screen must survive every screen size crossed with every system
/// text scale a user can actually set.
///
/// The chrome is built from fixed-size pieces — a 62dp bottom bar, 60x56 nav
/// rail chips, a rail with a fixed itemExtent — none of which can grow to
/// absorb larger text. Before this was guarded, the nav rail label wrapped onto
/// three lines and burst ~50dp out of its chip, and the bottom bar overflowed a
/// small phone by 40dp, painting overflow stripes across the navigation for
/// anyone using a large-text accessibility setting.
List<ChannelCategory> categories() => [
  ChannelCategory(
    name: 'ALWAN SPORT - باقة الوان الرياضية العربية',
    displayName: 'ALWAN SPORT - باقة الوان الرياضية العربية',
    channels: List.generate(
      8,
      (i) => Channel(
        name: 'beIN SPORTS $i HD',
        url: 'http://host/$i',
        group: 'رياضة',
        streamId: i,
      ),
    ),
    sortOrder: 0,
  ),
  ChannelCategory(
    name: 'movies',
    displayName: 'باقة أفلام',
    channels: List.generate(
      6,
      (i) => Channel(
        name: 'فيلم $i',
        url: 'http://host/m$i',
        group: 'أفلام',
        streamId: 100 + i,
      ),
    ),
    sortOrder: 1,
  ),
];

void main() {
  // The fixtures destination probes the owner's LAN. A widget test must not
  // open a socket: its timeout leaves a pending timer, and the result would
  // otherwise depend on which network the machine is on.
  setUp(() => FixturesService.debugSetAvailable(false));

  const sizes = <String, Size>{
    'Android TV 960x540': Size(960, 540),
    'Android TV 1440x810': Size(1440, 810),
    'tablet 1024x768': Size(1024, 768),
    'narrow window 720x900': Size(720, 900),
    'landscape phone 932x430': Size(932, 430),
    'phone 390x844': Size(390, 844),
    'small phone 320x568': Size(320, 568),
  };

  for (final entry in sizes.entries) {
    for (final scale in const [1.0, 1.5, 2.0, 3.0]) {
      testWidgets('${entry.key} @${scale}x has no overflow', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final overflows = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          final message = details.exceptionAsString();
          if (message.contains('overflowed')) overflows.add(message);
        };

        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: entry.value,
              textScaler: TextScaler.linear(scale),
            ),
            child: MaterialApp(
              theme: AppTheme.darkTheme,
              home: HomeScreen(preloadedCategories: categories()),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        FlutterError.onError = previous;

        expect(
          overflows,
          isEmpty,
          reason: '${entry.key} at ${scale}x: ${overflows.join(" | ")}',
        );
      });
    }
  }
}
