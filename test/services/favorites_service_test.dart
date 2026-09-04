import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/services/favorites_service.dart';
import 'package:myservices_tv/utils/channel_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

Channel makeChannel({
  String name = 'BEIN 1',
  String ext = 'ts',
  int streamId = 7,
  String group = 'رياضة',
  String tvgId = '',
}) => Channel(
  name: name,
  url: 'http://panel.test:8080/live/user/pass/$streamId.$ext',
  group: group,
  tvgId: tvgId,
  streamId: streamId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('legacy URL favourites survive a container-format change', () {
    test('a .m3u8 favourite still matches the same channel built as .ts', () {
      // The regression this guards: live URLs used to be hardcoded to .m3u8
      // and are now built as .ts, so a URL-keyed favourite list silently
      // emptied on upgrade.
      const legacyUrl = 'http://panel.test:8080/live/user/pass/7.m3u8';
      expect(
        FavoritesService.isFavorite(makeChannel(ext: 'ts'), {legacyUrl}),
        isTrue,
      );
    });

    test('resolves legacy entries against the current playlist', () async {
      const legacyUrl = 'http://panel.test:8080/live/user/pass/7.m3u8';
      SharedPreferences.setMockInitialValues({
        'favorite_channel_urls': <String>[legacyUrl],
      });

      final current = makeChannel(ext: 'ts');
      final favorites = await FavoritesService.getFavoriteChannels([
        ChannelCategory(
          name: 'رياضة',
          displayName: 'رياضة',
          channels: [current],
          sortOrder: 0,
        ),
      ]);

      expect(favorites, hasLength(1));
      expect(favorites.single.url, current.url);
    });

    test('un-favouriting a legacy entry removes it rather than duplicating',
        () async {
      const legacyUrl = 'http://panel.test:8080/live/user/pass/7.m3u8';
      SharedPreferences.setMockInitialValues({
        'favorite_channel_urls': <String>[legacyUrl],
      });

      final nowFavorite = await FavoritesService.toggleFavorite(
        makeChannel(ext: 'ts'),
      );

      expect(nowFavorite, isFalse, reason: 'it was already a favourite');
      expect(await FavoritesService.getFavoriteKeys(), isEmpty);
    });

    test('a different channel is not matched by a legacy URL', () {
      const legacyUrl = 'http://panel.test:8080/live/user/pass/7.m3u8';
      expect(
        FavoritesService.isFavorite(makeChannel(streamId: 8), {legacyUrl}),
        isFalse,
      );
    });
  });

  group('identity keys', () {
    test('toggling stores an identity key, not a URL', () async {
      await FavoritesService.toggleFavorite(makeChannel());
      final stored = await FavoritesService.getFavoriteKeys();

      expect(stored, {'stream:7'});
      expect(stored.single, isNot(contains('http')));
    });

    test('the key is stable across format and credential changes', () {
      final asTs = makeChannel(ext: 'ts');
      final asHls = makeChannel(ext: 'm3u8');
      expect(channelIdentityKey(asTs), channelIdentityKey(asHls));

      final rotated = Channel(
        name: 'BEIN 1',
        url: 'http://panel.test:8080/live/newuser/newpass/7.ts',
        group: 'رياضة',
        streamId: 7,
      );
      expect(channelIdentityKey(rotated), channelIdentityKey(asTs));
    });

    test('falls back through tvg-id then name+group without a stream id', () {
      final withTvg = Channel(
        name: 'MBC',
        url: 'http://host/a',
        tvgId: 'mbc.sa',
        group: 'عام',
      );
      expect(channelIdentityKey(withTvg), 'tvg:mbc.sa');

      final bare = Channel(name: 'MBC', url: 'http://host/a', group: 'عام');
      expect(channelIdentityKey(bare), 'name:mbc\u0000عام');
    });

    test('round-trips a toggle on an M3U channel with no stream id', () async {
      final channel = Channel(
        name: 'MBC',
        url: 'http://host/stream',
        group: 'عام',
      );
      expect(await FavoritesService.toggleFavorite(channel), isTrue);
      expect(
        FavoritesService.isFavorite(
          channel,
          await FavoritesService.getFavoriteKeys(),
        ),
        isTrue,
      );

      expect(await FavoritesService.toggleFavorite(channel), isFalse);
      expect(await FavoritesService.getFavoriteKeys(), isEmpty);
    });
  });

  group('normalizeStreamUrl', () {
    test('strips only known live containers', () {
      expect(
        normalizeStreamUrl('http://h/live/u/p/1.m3u8'),
        normalizeStreamUrl('http://h/live/u/p/1.ts'),
      );
      expect(normalizeStreamUrl('http://h/movie/u/p/1.mkv'),
          'http://h/movie/u/p/1.mkv');
    });

    test('tolerates junk without throwing', () {
      expect(normalizeStreamUrl(''), '');
      expect(normalizeStreamUrl('not a url'), 'not a url');
    });
  });
}
