import 'package:flutter_test/flutter_test.dart';

import 'package:music_player/models/track.dart';
import 'package:music_player/services/catalog.dart';
import 'package:music_player/services/equalizer.dart';
import 'package:music_player/services/keys.dart';
import 'package:music_player/services/lyrics.dart';
import 'package:music_player/sources/audiomack.dart';
import 'package:music_player/sources/net.dart';
import 'package:music_player/sources/zvuk.dart';

void main() {
  test('версии одной песни с разных площадок объединяются', () {
    const a = Track(source: 'yandex', id: '1', title: 'Song (feat. X) [Explicit]', artist: 'Artist');
    const b = Track(source: 'soundcloud', id: '2', title: 'song - Dirty', artist: 'ARTIST');
    const c = Track(source: 'youtube', id: 'x', title: 'Song (Official Video)', artist: 'Artist');
    expect(a.matchKey, b.matchKey);
    expect(a.matchKey, c.matchKey);
  });

  test('трек переживает сохранение в плейлист', () {
    const t = Track(
      source: 'soundcloud',
      id: '42',
      title: 'Title',
      artist: 'Artist',
      year: 2020,
      duration: Duration(seconds: 200),
      explicit: true,
      extra: {'auth': 'abc', 'transcodings': [{'url': 'u'}]},
    );
    final back = Track.fromJson(t.toJson());
    expect(back, t);
    expect(back.duration, t.duration);
    expect(back.explicit, true);
    expect(back.extra['transcodings'], isA<List>());
  });

  test('по умолчанию играет версия без цензуры, превью и видео — в последнюю очередь', () {
    const clean = Track(source: 'yandex', id: '1', title: 'Song', artist: 'A');
    const dirty = Track(source: 'soundcloud', id: '2', title: 'Song', artist: 'A', explicit: true);
    const video = Track(source: 'youtube', id: '3', title: 'Song', artist: 'A', explicit: true);
    const preview = Track(source: 'soundcloud', id: '4', title: 'Song', artist: 'A', explicit: true, previewOnly: true);
    final g = TrackGroup([clean, video, preview, dirty]);

    TrackGroup.preferExplicitDefault(true);
    expect(g.main, dirty);
    TrackGroup.preferExplicitDefault(false);
    expect(g.main, clean);
    TrackGroup.preferExplicitDefault(true);
  });

  test('подпись OAuth 1.0a для Audiomack совпадает с эталоном (.NET HMACSHA1)', () {
    final header = AudiomackSource.oauthHeader(
      method: 'GET',
      url: 'https://api.audiomack.com/v1/search',
      params: {'q': "lil uzi vert! (it's)", 'show': 'songs', 'limit': '20'},
      consumerKey: 'ck',
      consumerSecret: 'cs',
      nonce: 'abc',
      timestamp: '1700000000',
    );
    expect(header, contains('oauth_signature="${AudiomackSource.pct('75ASSZ6fUoFhA8XLALc5X9fO09A=')}"'));
    expect(header, startsWith('OAuth '));
  });

  test('обложка Звука: относительный путь и размер', () {
    expect(ZvukSource.coverUrl('/pic?type=release&id=5'), 'https://zvuk.com/pic?type=release&id=5&size=300x300');
    expect(ZvukSource.coverUrl('https://cdn.zvuk.com/pic?id=5&size={size}'), contains('size=300x300'));
    expect(ZvukSource.coverUrl(null), isNull);
  });

  test('сетевые сбои распознаются как временные', () {
    expect(Net.isTransient(Exception('HandshakeException: Connection terminated during handshake')), true);
    expect(Net.isTransient(Exception('Яндекс: токен недействителен')), false);
    expect(Net.describe(Exception('HandshakeException: Connection terminated during handshake')),
        contains('защищённое соединение'));
  });

  test('синхронный текст LRC разбирается по времени', () {
    final lines = LyricsService.parseLrc(
        ['[00:12.50] Первая строка', '[01:02.3]Вторая', '[00:05.00][00:30.00] Припев'].join('\n'));
    expect(lines.map((l) => l.text), ['Припев', 'Первая строка', 'Припев', 'Вторая']);
    expect(lines[1].time, const Duration(seconds: 12, milliseconds: 500));
    expect(lines.last.time, const Duration(minutes: 1, seconds: 2, milliseconds: 300));
  });

  test('название для поиска текста очищается от пометок', () {
    expect(LyricsService.cleanTitle('Nuke (feat. X) [Prod. Y]'), 'Nuke');
    expect(LyricsService.cleanTitle('Song - Explicit Version'), 'Song');
  });

  test('эквалайзер на ПК: фильтр mpv с запасом от хрипа', () {
    expect(EqualizerService.desktopFilter([60, 1000], [0, 0]), '');
    final f = EqualizerService.desktopFilter([60, 1000, 8000], [6, 0, -3]);
    expect(f, startsWith('lavfi=['));
    expect(f, contains('volume=volume=-4.2dB'));
    expect(f, contains('equalizer=f=60:t=o:w=1:g=6.0'));
    expect(f, contains('equalizer=f=8000:t=o:w=1:g=-3.0'));
    expect(f, isNot(contains('f=1000')));
  });

  test('та же песня находится, даже если загрузил другой человек', () {
    // как на SoundCloud: исполнитель — тот, кто загрузил, а настоящий — в названии
    const sc = Track(source: 'soundcloud', id: '1', title: 'LAZZY2WICE - TWISTED METAL', artist: 'some uploader');
    const zvuk = Track(source: 'zvuk', id: '2', title: 'Twisted Metal', artist: 'LAZZY2WICE');
    const other = Track(source: 'zvuk', id: '3', title: 'Twisted Metal', artist: 'Совсем другой');
    final (artists, title) = CatalogService.matchKeys(sc);
    expect(CatalogService.sameSong(zvuk, artists, title), true);
    expect(CatalogService.sameSong(other, artists, title), false);
  });

  test('свой ключ из настроек важнее встроенного', () {
    expect(AppKeys.pick('mine', 'built'), 'mine');
    expect(AppKeys.pick('  ', 'built'), 'built');
    expect(AppKeys.pick(null, ''), isNull);
  });

  test('адрес прокси без https дополняется', () {
    expect(Net.normalize('music-proxy.x.workers.dev'), 'https://music-proxy.x.workers.dev');
    expect(Net.normalize(' https://music-proxy.x.workers.dev/ '), 'https://music-proxy.x.workers.dev');
    expect(Net.normalize(''), '');
  });

  test('пометки uncensored/dirty распознаются как explicit', () {
    expect(Track.explicitTags.hasMatch('Song (Uncensored)'), true);
    expect(Track.explicitTags.hasMatch('Song [Dirty Version]'), true);
    expect(Track.explicitTags.hasMatch('Song (Clean)'), false);
  });
}
