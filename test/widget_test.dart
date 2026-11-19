import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:music_player/models/track.dart';
import 'package:music_player/services/catalog.dart';
import 'package:music_player/services/equalizer.dart';
import 'package:music_player/services/importer.dart';
import 'package:music_player/services/keys.dart';
import 'package:music_player/services/library.dart';
import 'package:music_player/services/lyrics.dart';
import 'package:music_player/sources/audiomack.dart';
import 'package:music_player/sources/net.dart';
import 'package:music_player/sources/zvuk.dart';

void main() {
  test('версии одной песни с разных площадок объединяются', () {
    const a = Track(source: 'zvuk', id: '1', title: 'Song (feat. X) [Explicit]', artist: 'Artist');
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
    const clean = Track(source: 'zvuk', id: '1', title: 'Song', artist: 'A');
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

  test('токен Звука находится во вставленной странице профиля целиком', () {
    const page = '{"result":{"profile":{"name":"Fembi"},"token":"abc123XYZ","is_anonymous":false}}';
    expect(ZvukSource.extractToken(page), 'abc123XYZ');
    expect(ZvukSource.extractToken('  "abc123XYZ"  '), 'abc123XYZ');
    expect(ZvukSource.extractToken(''), '');
  });

  test('сетевые сбои распознаются как временные', () {
    expect(Net.isTransient(Exception('HandshakeException: Connection terminated during handshake')), true);
    expect(Net.isTransient(Exception('Звук: токен не подошёл')), false);
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

  test('«не нравится» по исполнителю: соавторы не мешают узнать того же исполнителя', () {
    expect(Library.artistKey('LAZZY2WICE, Kai Angel'), Library.artistKey('lazzy2wice'));
    expect(Library.artistKey('LAZZY2WICE feat. X'), 'lazzy2wice');
  });

  test('импорт: строки «Исполнитель — Песня» с нумерацией и длительностью', () {
    final l = PlaylistImporter.parse(['1. LAZZY2WICE — Nuke', '02) Kai Angel - Hurricane (3:12)', '• Jay-Z – 99 Problems',
        'Просто название', ''].join('\n'));
    expect(l.map((x) => '${x.artist}|${x.title}'),
        ['LAZZY2WICE|Nuke', 'Kai Angel|Hurricane', 'Jay-Z|99 Problems', '|Просто название']);
  });

  test('импорт из файла: UTF-8 с BOM, UTF-16 и Windows-1251', () {
    const text = 'Ёлка — Привет';
    final utf8Bom = [0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
    final utf16le = [0xFF, 0xFE, for (final c in text.codeUnits) ...[c & 0xFF, c >> 8]];
    // Windows-1251: Ё=0xA8, А..я=0xC0..0xFF, «—»=0x97
    final cp1251 = [
      for (final c in text.runes)
        c == 0x0401 ? 0xA8 : (c == 0x2014 ? 0x97 : (c >= 0x0410 && c <= 0x044F ? 0xC0 + (c - 0x0410) : c))
    ];
    expect(PlaylistImporter.decodeFile(utf8Bom), text);
    expect(PlaylistImporter.decodeFile(utf16le), text);
    expect(PlaylistImporter.decodeFile(cp1251), text);
  });

  test('импорт: таблица CSV с колонками названия и исполнителя', () {
    final l = PlaylistImporter.parse(['Track name,Artist name,Album', '"Nuke, pt. 2",LAZZY2WICE,X', 'Song,Artist,Y'].join('\n'));
    expect(l.map((x) => '${x.artist}|${x.title}'), ['LAZZY2WICE|Nuke, pt. 2', 'Artist|Song']);
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
