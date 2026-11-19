// Нестандартные тесты: граничные и «странные» входные данные, поддельные площадки,
// которые падают, молчат, отвечают мусором или не подключены.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:music_player/models/track.dart';
import 'package:music_player/services/catalog.dart';
import 'package:music_player/services/equalizer.dart';
import 'package:music_player/services/importer.dart';
import 'package:music_player/services/library.dart';
import 'package:music_player/services/lyrics.dart';
import 'package:music_player/services/search_service.dart';
import 'package:music_player/sources/audiomack.dart';
import 'package:music_player/sources/net.dart';
import 'package:music_player/sources/source.dart';
import 'package:music_player/sources/zvuk.dart';
import 'package:music_player/ui/source_filter.dart';

/// Поддельная площадка: отвечает заданными треками, падает или «не подключена».
class FakeSource extends MusicSource {
  @override
  final String id;
  @override
  String get name => 'Fake-$id';
  final Map<String, List<Track>> results;
  final Object? error;
  final bool configured;
  final Map<String, AlbumInfo> albums;
  final Map<String, ArtistInfo> artists;
  final List<ArtistRef> artistResults;
  int searchCalls = 0;

  FakeSource(
    this.id, {
    this.results = const {},
    this.error,
    this.configured = true,
    this.albums = const {},
    this.artists = const {},
    this.artistResults = const [],
  });

  @override
  bool get isConfigured => configured;
  @override
  bool get hasCatalog => albums.isNotEmpty || artists.isNotEmpty;

  @override
  Future<List<Track>> search(String query) async {
    searchCalls++;
    if (error != null) throw error!;
    return results[query] ?? results['*'] ?? const [];
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async => StreamInfo(Uri.parse('https://example.test/${track.id}.mp3'));

  @override
  Future<AlbumInfo?> album(String albumId) async => albums[albumId];
  @override
  Future<ArtistInfo?> artist(String artistId) async => artists[artistId];
  @override
  Future<List<ArtistRef>> searchArtists(String query) async => artistResults;
}

Track t(String source, String id, String artist, String title,
        {bool explicit = false, bool preview = false, String? albumId, Duration? duration}) =>
    Track(
      source: source,
      id: id,
      title: title,
      artist: artist,
      explicit: explicit,
      previewOnly: preview,
      duration: duration,
      extra: {if (albumId != null) 'albumId': albumId},
    );

void main() {
  group('Поиск: площадки, которые ведут себя плохо', () {
    test('одна площадка падает — остальные результаты всё равно приходят, ошибка видна', () async {
      final good = FakeSource('good', results: {'*': [t('good', '1', 'A', 'Song')]});
      final bad = FakeSource('bad', error: Exception('сервер лёг'));
      final r = await SearchService([good, bad]).search('A Song');
      expect(r.done, true);
      expect(r.groups.single.main.source, 'good');
      expect(r.errors.keys, ['Fake-bad']);
      expect(r.errors.values.single, contains('сервер лёг'));
    });

    test('все площадки упали — пустой результат, а не зависание', () async {
      final r = await SearchService([
        FakeSource('a', error: TimeoutException('долго')),
        FakeSource('b', error: StateError('мусор')),
      ]).search('x');
      expect(r.groups, isEmpty);
      expect(r.errors.length, 2);
      expect(r.done, true);
    });

    test('ни одной подключённой площадки — сразу пустой готовый результат', () async {
      final r = await SearchService([FakeSource('a', configured: false)]).search('x');
      expect(r.done, true);
      expect(r.groups, isEmpty);
      expect(r.errors, isEmpty);
    });

    test('поток результатов: сначала частичный, последний — полный', () async {
      final events = await SearchService([
        FakeSource('a', results: {'*': [t('a', '1', 'A', 'One')]}),
        FakeSource('b', results: {'*': [t('b', '2', 'B', 'Two')]}),
      ]).searchStream('q').toList();
      expect(events.length, 2);
      expect(events.first.done, false);
      expect(events.last.done, true);
      expect(events.last.groups.length, 2);
    });

    test('повторный поиск берётся из кэша, неудачный — нет', () async {
      final ok = FakeSource('ok', results: {'*': [t('ok', '1', 'A', 'S')]});
      final s = SearchService([ok]);
      await s.search('Same Query');
      await s.search('  same query  '); // регистр и пробелы не важны
      expect(ok.searchCalls, 1);

      final flaky = FakeSource('flaky', error: Exception('сбой'));
      final s2 = SearchService([flaky]);
      await s2.search('q');
      await s2.search('q');
      expect(flaky.searchCalls, 2, reason: 'результат с ошибкой не должен кэшироваться');
    });

    test('одна песня с разных площадок — одна карточка; разные исполнители — разные', () async {
      final r = await SearchService([
        FakeSource('a', results: {'*': [t('a', '1', 'Artist', 'Song (feat. X)'), t('a', '2', 'Other', 'Song')]}),
        FakeSource('b', results: {'*': [t('b', '3', 'ARTIST', 'song [Explicit]', explicit: true)]}),
      ]).search('q');
      expect(r.groups.length, 2);
      final g = r.groups.firstWhere((g) => g.variants.length == 2);
      expect(g.main.explicit, true, reason: 'по умолчанию предпочитаем версию без цензуры');
    });

    test('трек удалённой площадки не роняет плеер: заглушка вместо исключения', () async {
      final s = SearchService([FakeSource('a')]);
      final src = s.sourceOf(t('audius', '1', 'A', 'B'));
      expect(src, isA<RemovedSource>());
      expect(src.name, 'Audius');
      await expectLater(src.streamUrl(t('audius', '1', 'A', 'B')), throwsException);
      expect(await src.search('x'), isEmpty);
    });
  });

  group('Названия и сравнение песен', () {
    test('эмодзи, кириллица, Ё и мусорные символы', () {
      expect(Track.normalize('🔥 Ёлка!!!  —  Привет 🔥'), 'ёлка привет');
      expect(Track.normalize(''), '');
      expect(Track.normalize('   '), '');
    });

    test('название целиком в скобках не превращается в пустоту', () {
      final a = t('a', '1', 'X', '(Intro)');
      final b = t('a', '2', 'X', '(Outro)');
      expect(a.matchKey, isNot(b.matchKey));
    });

    test('песня только из превью: основной версией всё равно будет она', () {
      final g = TrackGroup([t('a', '1', 'A', 'S', preview: true)]);
      expect(g.main.previewOnly, true);
    });

    test('похожее, но другое название не считается той же песней', () {
      final (artists, title) = CatalogService.matchKeys(t('a', '1', 'A', 'Up'));
      expect(CatalogService.sameSong(t('b', '2', 'A', 'Upside Down'), artists, title), false);
      expect(CatalogService.sameSong(t('b', '3', 'A', 'Up'), artists, title), true);
    });

    test('исполнитель с соавторами и «x»', () {
      expect(Library.artistKey('Kai Angel x 9mice'), 'kai angel');
      expect(Library.artistKey(''), '');
    });
  });

  group('Импорт плейлиста: странные списки', () {
    String fmt(List<ImportLine> l) => l.map((x) => '${x.artist}|${x.title}').join(' / ');

    test('цифры в имени исполнителя — не нумерация', () {
      expect(
        fmt(PlaylistImporter.parse(['50 Cent - In Da Club', '21 Savage — a lot', '2Pac - Changes'].join('\n'))),
        '50 Cent|In Da Club / 21 Savage|a lot / 2Pac|Changes',
      );
    });

    test('разные виды нумерации всё же убираются', () {
      expect(
        fmt(PlaylistImporter.parse(['1. A - S', '02) B - T', '#3 C - U', '4: D - V', '• E - W'].join('\n'))),
        'A|S / B|T / C|U / D|V / E|W',
      );
    });

    test('пустые строки, пробелы и строка из одного тире пропускаются без падения', () {
      final l = PlaylistImporter.parse(['', '   ', ' - ', '—', 'A - S'].join('\n'));
      expect(l.where((x) => x.title.isNotEmpty).map((x) => x.title), contains('S'));
    });

    test('CSV через точку с запятой и табуляцию, кавычки внутри кавычек', () {
      expect(fmt(PlaylistImporter.parse(['Title;Artist', 'Song;Band'].join('\n'))), 'Band|Song');
      expect(fmt(PlaylistImporter.parse(['Name\tArtist', 'Song\tBand'].join('\n'))), 'Band|Song');
      expect(
        fmt(PlaylistImporter.parse(['Track,Artist', '"Say ""Hi"", ok",Band'].join('\n'))),
        'Band|Say "Hi", ok',
      );
    });

    test('CSV только с заголовком — не ломается, читается как обычный список', () {
      expect(() => PlaylistImporter.parse('Track,Artist'), returnsNormally);
    });

    test('очень длинный список разбирается быстро', () {
      final big = List.generate(5000, (i) => '$i. Artist $i - Song $i').join('\n');
      final sw = Stopwatch()..start();
      final l = PlaylistImporter.parse(big);
      expect(l.length, 5000);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('файлы: пустой, обрезанный UTF-16, мусорные байты', () {
      expect(PlaylistImporter.decodeFile([]), '');
      expect(() => PlaylistImporter.decodeFile([0xFF, 0xFE, 0x41]), returnsNormally); // нечётная длина
      expect(() => PlaylistImporter.decodeFile([0xC3, 0x28, 0xFF]), returnsNormally); // битый UTF-8
      expect(PlaylistImporter.decodeFile(utf8.encode('A - B')), 'A - B');
    });

    test('поиск песни: чужой исполнитель и превью не подставляются, explicit — предпочитается', () async {
      final src = FakeSource('a', results: {
        '*': [
          t('a', '1', 'Wrong Artist', 'Nuke'),
          t('a', '2', 'LAZZY2WICE', 'Nuke', preview: true),
          t('a', '3', 'LAZZY2WICE', 'Nuke'),
          t('a', '4', 'LAZZY2WICE', 'Nuke', explicit: true),
        ]
      });
      final found = await PlaylistImporter(SearchService([src])).find(const ImportLine('', 'LAZZY2WICE', 'Nuke'));
      expect(found?.id, '4');
      final none = await PlaylistImporter(SearchService([src])).find(const ImportLine('', 'Nobody', 'Nuke'));
      expect(none, isNull);
    });

    test('импорт со «Стоп» посередине завершается и не зависает', () async {
      final items = [for (var i = 0; i < 20; i++) ImportItem(ImportLine('', 'A', 'S$i'))];
      var updates = 0;
      await PlaylistImporter(SearchService([FakeSource('a')])).run(
        items,
        onUpdate: () => updates++,
        cancelled: () => updates > 6,
      );
      expect(items.where((i) => i.status == ImportStatus.waiting), isNotEmpty);
    });
  });

  group('Альбомы и исполнители: честный отчёт', () {
    test('неподключённая площадка попадает в отчёт, альбом находится на другой', () async {
      final song = t('zvuk', '7', 'LAZZY2WICE', 'Twisted Metal', albumId: 'al1');
      final album = AlbumInfo(const AlbumRef(source: 'zvuk', id: 'al1', title: 'EP', artist: 'LAZZY2WICE'), [song]);
      final zvuk = FakeSource('zvuk', results: {'*': [song]}, albums: {'al1': album});
      final off = FakeSource('soundcloud', configured: false, albums: {'x': album});
      final catalog = CatalogService(SearchService([zvuk, off]));
      final sc = t('youtube', 'v', 'some uploader', 'LAZZY2WICE - TWISTED METAL');
      final a = await catalog.albumFor(sc);
      expect(a?.ref.id, 'al1');

      final miss = await CatalogService(SearchService([off])).albumFor(sc);
      expect(miss, isNull);
    });

    test('отчёт при неудаче называет каждую площадку', () async {
      final off = FakeSource('soundcloud', configured: false, albums: {'x': const AlbumInfo(AlbumRef(source: 's', id: 'x', title: 't', artist: 'a'), [])});
      final broken = FakeSource('zvuk', error: Exception('сбой'), albums: {'y': const AlbumInfo(AlbumRef(source: 'z', id: 'y', title: 't', artist: 'a'), [])});
      final c = CatalogService(SearchService([off, broken]));
      expect(await c.albumFor(t('youtube', '1', 'A', 'B')), isNull);
      expect(c.lastReport, contains('не подключён'));
      expect(c.lastReport, contains('сбой'));
    });

    test('исполнитель: близкое имя подходит, совсем другое — нет', () async {
      const info = ArtistInfo(ArtistRef(source: 'zvuk', id: 'a1', name: 'LAZZY2WICE'));
      ArtistRef ref(String n) => ArtistRef(source: 'zvuk', id: 'a1', name: n);
      final close = FakeSource('zvuk', artists: {'a1': info}, artistResults: [ref('LAZZY 2WICE')]);
      expect(await CatalogService(SearchService([close])).artistByName('LAZZY2WICE'), isNotNull);
      final far = FakeSource('zvuk', artists: {'a1': info}, artistResults: [ref('Lazzy Twice and the Orchestra')]);
      expect(await CatalogService(SearchService([far])).artistByName('LAZZY2WICE'), isNull);
    });
  });

  group('Тексты, токены, ключи, фильтры', () {
    test('LRC: мусор, метаданные и строки без времени не ломают разбор', () {
      expect(LyricsService.parseLrc(''), isEmpty);
      expect(LyricsService.parseLrc('просто текст\nбез меток'), isEmpty);
      final l = LyricsService.parseLrc(['[ar:Artist]', '[ti:Song]', '[00:10.5]a', '[99:59.999]b'].join('\n'));
      expect(l.map((x) => x.text), ['a', 'b']);
      expect(l.first.time, const Duration(seconds: 10, milliseconds: 500));
    });

    test('чистка названия для поиска текста: пустое и только скобки', () {
      expect(LyricsService.cleanTitle(''), '');
      expect(() => LyricsService.cleanTitle('(((('), returnsNormally);
    });

    test('токен Звука: пробелы вокруг, переносы, лишние поля', () {
      expect(ZvukSource.extractToken('{\n  "token" :  "t0k"\n}'), 't0k');
      expect(ZvukSource.extractToken('"result":{"token":"A"},"other":{"token":"B"}'), 'A');
    });

    test('обложка Звука: старый size заменяется, а не дублируется', () {
      final u = ZvukSource.coverUrl('https://cdn.zvuk.com/pic?id=1&size=100x100')!;
      expect(Uri.parse(u).queryParametersAll['size'], ['300x300']);
    });

    test('подпись Audiomack: кириллица и спецсимволы кодируются по RFC 3986', () {
      expect(AudiomackSource.pct("рэп!*'()"), '%D1%80%D1%8D%D0%BF%21%2A%27%28%29');
      expect(AudiomackSource.pct('a-b_c.d~e'), 'a-b_c.d~e');
    });

    test('сеть: таймаут считается временным сбоем', () {
      expect(Net.isTransient(TimeoutException('x')), true);
      expect(Net.describe(TimeoutException('x')), contains('не ответил'));
      expect(Net.normalize('http://local:8787/'), 'http://local:8787');
    });

    test('эквалайзер на ПК: только срезы — без снижения громкости; огромные значения не ломают', () {
      expect(EqualizerService.desktopFilter([60, 1000], [-6, -3]), isNot(contains('volume=')));
      expect(() => EqualizerService.desktopFilter([60], [1e9]), returnsNormally);
    });

    test('фильтр площадок: неизвестная площадка даёт пустой список, null — всё', () {
      final groups = [TrackGroup([t('a', '1', 'A', 'S')])];
      expect(filterGroups(groups, 'nope'), isEmpty);
      expect(filterGroups(groups, null), same(groups));
    });
  });
}
