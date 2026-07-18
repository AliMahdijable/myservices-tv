import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/utils/search_helpers.dart';

void main() {
  test(
    'normalizes Arabic alef variants, diacritics, tatweel and whitespace',
    () {
      expect(normalizeSearchText('  إِخْبَــار  آلعِراق  '), 'اخبار العراق');
    },
  );

  test('searches tvgName and removes duplicate channel URLs', () {
    final duplicate = Channel(
      name: 'اسم بديل',
      tvgName: 'العراقية الرياضية',
      url: 'HTTP://example.test/live/1.m3u8',
    );
    final original = Channel(
      name: 'Sports One',
      tvgName: 'العراقية الرياضية',
      url: 'http://example.test/live/1.m3u8',
    );
    final index = ChannelSearchIndex([original, duplicate]);

    final results = index.search('العِرَاقِيَّة');

    expect(index.length, 1);
    expect(results.total, 1);
    expect(results.channels, [original]);
  });

  test('reports all matches while limiting visible results', () {
    final index = ChannelSearchIndex([
      for (var i = 0; i < 150; i++)
        Channel(name: 'Channel $i', url: 'http://example.test/$i'),
    ]);

    final results = index.search('channel');

    expect(results.total, 150);
    expect(results.channels, hasLength(maxVisibleSearchResults));

    final countOnly = index.search('channel', limit: 0);
    expect(countOnly.total, 150);
    expect(countOnly.channels, isEmpty);
  });

  test('matches multiple words regardless of their order', () {
    final index = ChannelSearchIndex([
      Channel(name: 'العراقية الرياضية', url: 'http://example.test/sports'),
    ]);

    final results = index.search('رياضية عراقية');

    expect(results.total, 1);
    expect(results.channels.single.name, 'العراقية الرياضية');
  });
}
