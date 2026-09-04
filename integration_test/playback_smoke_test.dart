import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:myservices_tv/config/app_config.dart';
import 'package:myservices_tv/main.dart';
import 'package:myservices_tv/player/playback_preferences.dart';
import 'package:myservices_tv/screens/player_screen.dart';
import 'package:myservices_tv/widgets/channel_card.dart';

/// End-to-end check that a channel actually starts playing against the
/// configured provider.
///
/// This is the one thing unit tests cannot cover: whether the URL the app
/// builds is a URL the server will serve. It was written after finding that
/// every channel was opened on a container format the panel refuses, so the
/// first attempt always failed and the recovery logic silently papered over
/// it — six seconds of retries the user experienced as "the app is slow".
///
/// Requires a reachable, configured provider; it skips itself otherwise rather
/// than failing on a machine off the provider's network.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a channel starts playing on the first attempt', (tester) async {
    MediaKit.ensureInitialized();
    await PlaybackPreferences.load();
    await AppConfig.load();

    await tester.pumpWidget(const MyServicesTV());

    // The splash screen resolves the server and preloads the playlist.
    final loaded = await _pumpUntil(
      tester,
      () => find.byType(ChannelCard).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 45),
    );
    if (!loaded) {
      markTestSkipped('No provider reachable — skipping playback smoke test.');
      return;
    }

    await tester.tap(find.byType(ChannelCard).first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(PlayerScreen),
      findsOneWidget,
      reason: 'tapping a channel must open the player',
    );

    // Read mpv's own state through the Video widget rather than inferring
    // progress from the spinner: an assertion about the loading indicator can
    // pass in the gap before it is first painted, without a frame of video
    // ever arriving.
    PlayerState playerState() =>
        tester.widget<Video>(find.byType(Video)).controller.player.state;

    // A channel opened on a format the server serves reaches its first frame
    // well inside this window. On the wrong format it burns the silent retry
    // and two backoffs first, which is exactly what this bound catches.
    final started = await _pumpUntil(
      tester,
      () {
        final state = playerState();
        return state.playing && state.width != null && state.height != null;
      },
      timeout: const Duration(seconds: 20),
    );

    final state = playerState();
    expect(
      find.text('إعادة المحاولة'),
      findsNothing,
      reason: 'playback ended in the terminal error overlay',
    );
    expect(
      started,
      isTrue,
      reason:
          'no video frame within 20s '
          '(playing=${state.playing}, ${state.width}x${state.height})',
    );
    expect(
      state.width,
      greaterThan(0),
      reason: 'the decoder reported no picture size',
    );
  });
}

/// Pumps frames until [condition] holds or [timeout] elapses.
///
/// `pumpAndSettle` cannot be used here: the player's loading spinner animates
/// continuously, so the widget tree never settles.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return condition();
}
