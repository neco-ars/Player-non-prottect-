// Рекомендации, радио и синхронизация: поддельный «граф вкусов» и поддельные площадки.
import 'package:flutter_test/flutter_test.dart' hide Tags;

import 'package:music_player/models/track.dart';
import 'package:music_player/services/catalog.dart';
import 'package:music_player/services/library.dart';
import 'package:music_player/services/recommendations.dart';
import 'package:music_player/services/search_service.dart';
import 'package:music_player/services/sync.dart';
import 'package:music_player/services/tags.dart';
import 'package:music_player/services/taste.dart';
import 'package:music_player/sources/net.dart';

import 'edge_cases_test.dart' show FakeSource, t;

Track hint(String artist, String title, {int secs = 180, bool explicit = false}) => Track(
      source: Track.pickSource,
      id: 'dz-$artist-$title',
      title: title,
      artist: artist,
      duration: Duration(seconds: secs),
      explicit: explicit,
    );

/// Граф вкусов без сети.
class FakeGraph extends TasteGraph {
  final Map<String, List<Track>> radios;
  final Map<String, List<String>> rel;
  final bool broken;
  FakeGraph({this.radios = const {}, this.rel = const {}, this.broken = false});

  final _names = <int, String>{};
  int _id(String name) {
    final id = name.toLowerCase().hashCode;
    _names[id] = name;
    return id;
  }

  @override
  Future<TasteArtist?> findArtist(String name) async {
    if (broken) throw Exception('Deezer недоступен');
    return radios.containsKey(name) || rel.containsKey(name) ? TasteArtist(_id(name), name, null) : null;
  }

  @override
  Future<TasteArtist?> artistForTrack(String artist, String title) => findArtist(artist);

  @override
  Future<List<Track>> artistRadio(int artistId) async => List.of(radios[_names[artistId]] ?? const []);
  @override
  Future<List<Track>> artistTop(int artistId, {int limit = 10}) async =>
      (radios[_names[artistId]] ?? const []).where((x) => x.artist == _names[artistId]).take(limit).toList();
  @override
  Future<List<TasteArtist>> related(int artistId) async =>
      [for (final r in rel[_names[artistId]] ?? const <String>[]) TasteArtist(_id(r), r, null)];
  @override
  Future<List<Track>> chart() async => broken ? throw Exception('нет') : [];
}

/// Теги без сети: исполнитель → теги.
class FakeTags extends TagService {
  final Map<String, Map<String, double>> byArtist;
  FakeTags(this.byArtist) : super(key: '');
  Tags _of(String artist) => TagService.normalize(byArtist[Library.artistKey(artist)] ?? const {});
  @override
  Future<Tags> artistTags(String artist, {String? zvukArtistId}) async => _of(artist);
  @override
  Future<Tags> trackTags(Track t, {String? artist}) async => _of(artist ?? t.artist);
  @override
  Tags cachedTrackTags(Track t, {String? artist}) => _of(artist ?? t.artist);
  @override
  Future<void> prefetch(Iterable<String> artists, {int parallel = 8}) async {}
  @override
  Future<(Tags, Tags)> profile(Library library, {bool force = false}) async {
    final s = library.artistScores().values;
    return (
      TagService.blend([for (final x in s) if (x.$2 > 0) (_of(x.$1), x.$2)]),
      TagService.blend([for (final x in s) if (x.$2 < 0) (_of(x.$1), -x.$2)]),
    );
  }
}

/// SoundCloud с «станцией трека».
class FakeSoundCloud extends FakeSource {
  final List<Track> stationTracks;
  FakeSoundCloud({super.results, this.stationTracks = const []}) : super('soundcloud');
  @override
  Future<List<Track>> station(Track track) async => stationTracks;
}

/// Площадка, где по запросу «исполнитель название» находится ровно эта песня.
FakeSource playable(String id, List<Track> songs) => FakeSource(id, results: {
      for (final s in songs) '${s.artist} ${s.title}': [s],
    });

Recommendations recs(List<FakeSource> sources, Library lib, TasteGraph g) {
  final search = SearchService(sources);
  return Recommendations(search, lib, CatalogService(search), graph: g);
}

void main() {
  group('Подсказка → трек с площадки', () {
    test('берётся та же песня близкой длины, а не ремикс и не однофамилец', () async {
      final remix = t('soundcloud', 'r', 'Fan', 'Ka50 (speed up)', duration: const Duration(seconds: 120));
      final good = t('zvuk', 'g', 'LAZZY2WICE', 'Ka50', duration: const Duration(seconds: 162));
      final other = t('zvuk', 'o', 'Кто-то', 'Ka50', duration: const Duration(seconds: 160));
      final src = FakeSource('zvuk', results: {'LAZZY2WICE Ka50': [remix, other, good]});
      final r = recs([src], Library.memory(), FakeGraph());
      final got = await r.resolve(hint('LAZZY2WICE', 'Ka50', secs: 161));
      expect(got, good);
    });

    test('нигде нет — null, и повторно в сеть не ходим', () async {
      final src = FakeSource('zvuk');
      final r = recs([src], Library.memory(), FakeGraph());
      expect(await r.resolve(hint('Nobody', 'Nothing')), isNull);
      expect(await r.resolve(hint('Nobody', 'Nothing')), isNull);
      expect(src.searchCalls, 1);
    });

    test('превью и видео не подходят', () async {
      final prev = t('soundcloud', 'p', 'A', 'Song', preview: true);
      final src = FakeSource('soundcloud', results: {'A Song': [prev]});
      final r = recs([src], Library.memory(), FakeGraph());
      expect(await r.resolve(hint('A', 'Song')), isNull);
    });

    test('обычный трек возвращается как есть', () async {
      final r = recs([], Library.memory(), FakeGraph());
      final x = t('zvuk', '1', 'A', 'B');
      expect(await r.resolve(x), x);
    });
  });

  group('Радио', () {
    final songs = [
      for (final a in ['Seed', 'Near1', 'Near2', 'Bad'])
        for (var i = 0; i < 4; i++) t('zvuk', '$a$i', a, '$a song $i', duration: const Duration(seconds: 180)),
    ];
    List<Track> hintsOf(List<String> artists) => [
          for (final s in songs)
            if (artists.contains(s.artist)) hint(s.artist, s.title),
        ];

    test('радио по треку: песни с площадок, без «Скрытого» и без исполнителей подряд', () async {
      final lib = Library.memory();
      lib.dislike(songs.firstWhere((s) => s.artist == 'Bad'));
      final g = FakeGraph(radios: {'Seed': hintsOf(['Seed', 'Near1', 'Near2', 'Bad'])}, rel: {'Seed': ['Near1']});
      final r = recs([playable('zvuk', songs)], lib, g);
      final seed = songs.first;
      final batch = await r.radioBatch(RadioSeed.track(seed), {seed.key, seed.matchKey}, want: 10);
      expect(batch, isNotEmpty);
      expect(batch.every((x) => x.source == 'zvuk' && !x.isPick), isTrue);
      expect(batch.any((x) => x.artist == 'Bad'), isFalse);
      expect(batch.contains(seed), isFalse);
      expect(batch.map((x) => x.matchKey).toSet().length, batch.length);
      for (var i = 1; i < batch.length; i++) {
        final same = batch[i].artist == batch[i - 1].artist;
        // подряд — только если иначе никак
        if (same) expect(batch.skip(i).every((x) => x.artist == batch[i].artist), isTrue);
      }
    });

    test('радио по треку со станции SoundCloud: без перезаливов, минусовок и не больше четверти от исполнителя',
        () async {
      Duration s(int x) => Duration(seconds: x);
      final seedSc = t('soundcloud', 'seed', 'die!', 'die! - BESTGORE', duration: s(101));
      final station = [
        for (var i = 0; i < 8; i++) t('soundcloud', 'own$i', 'die!', 'own song $i', duration: s(150)),
        t('soundcloud', 'r1', 'randomguy', 'die! - own song 0', duration: s(150)), // перезалив
        t('soundcloud', 'r2', 'noname', 'own song 1', duration: s(150)), // перезалив без имени
        t('soundcloud', 'r3', 'ati_hell', 'die! STAY SAFE', duration: s(150)), // перезалив без дефиса
        t('soundcloud', 'r4', 'ati_hell', 'die! Ржавая молодость', duration: s(150)),
        t('soundcloud', 'm1', 'Machine Girl', 'Ghost', duration: s(180)),
        t('soundcloud', 'm2', 'Machine Girl', 'Ghost (instrumental)', duration: s(180)),
        t('soundcloud', 'k1', 'Kero Kero Bonito', 'Flamingo', duration: s(170)),
        t('soundcloud', 'p1', 'PLAYDATE', 'ALTERNATIVE', duration: s(160)),
        t('soundcloud', 'set', 'DJ', 'Live set 2015', duration: const Duration(minutes: 58)),
      ];
      final sc = FakeSoundCloud(results: {'die! BESTGORE': [seedSc]}, stationTracks: station);
      final r = recs([sc], Library.memory(), FakeGraph());
      final seed = t('zvuk', 'z', 'die!', 'BESTGORE (prod by blindcavegoblin)', duration: s(101));
      final batch = await r.radioBatch(RadioSeed.track(seed), {seed.key}, want: 8);
      final titles = batch.map((x) => x.title).toList();
      expect(batch.where((x) => Recommendations.trueArtist(x) == 'die!' || x.title.contains('die!')).length,
          lessThanOrEqualTo(2));
      expect(titles, contains('Ghost'));
      expect(titles, contains('Flamingo'));
      expect(titles.any((x) => x.contains('instrumental') || x.contains('Live set')), isFalse);
      expect(batch.map(Recommendations.titleKey).toSet().length, batch.length); // ни одной песни дважды
    });

    test('исполнитель, которого в этом радио пропустили дважды, больше не попадается', () async {
      final g = FakeGraph(radios: {'Seed': hintsOf(['Seed', 'Near1', 'Near2'])});
      final r = recs([playable('zvuk', songs)], Library.memory(), g);
      final s = RadioSession()
        ..skip(songs.firstWhere((x) => x.artist == 'Near1'))
        ..skip(songs.lastWhere((x) => x.artist == 'Near1'));
      final batch = await r.radioBatch(RadioSeed.track(songs.first), {}, session: s);
      expect(batch.any((x) => x.artist == 'Near1'), isFalse);
      expect(batch, isNotEmpty);
    });

    test('граф недоступен — запасной путь через треки исполнителя на площадках', () async {
      final seedSongs = songs.where((s) => s.artist == 'Seed').toList();
      final src = FakeSource('zvuk', results: {'Seed': seedSongs});
      final r = recs([src], Library.memory(), FakeGraph(broken: true));
      final batch = await r.radioBatch(RadioSeed.track(seedSongs.first), {seedSongs.first.key});
      expect(batch, isNotEmpty);
      expect(batch.every((x) => x.artist == 'Seed'), isTrue);
    });

    test('«Моя волна» строится от любимых исполнителей', () async {
      final lib = Library.memory();
      for (var i = 0; i < 5; i++) {
        lib.recordPlay(songs.firstWhere((s) => s.artist == 'Near2'));
      }
      final g = FakeGraph(radios: {'Near2': hintsOf(['Near2', 'Near1'])});
      final r = recs([playable('zvuk', songs)], lib, g);
      final batch = await r.radioBatch(RadioSeed.wave, {});
      expect(batch, isNotEmpty);
      expect(batch.every((x) => x.artist == 'Near2' || x.artist == 'Near1'), isTrue);
    });
  });

  group('Вкус', () {
    test('пропуски опускают исполнителя, «Скрытое» убирает совсем', () {
      final lib = Library.memory();
      final a = t('zvuk', '1', 'A', 'x'), b = t('zvuk', '2', 'B', 'y'), c = t('zvuk', '3', 'C', 'z');
      for (var i = 0; i < 3; i++) {
        lib.recordPlay(a);
        lib.recordPlay(b);
      }
      for (var i = 0; i < 3; i++) {
        lib.recordSkip(b);
      }
      lib.recordPlay(c);
      lib.dislike(c);
      final top = lib.topArtists();
      expect(top.first, 'A');
      expect(top.contains('C'), isFalse);
      expect(lib.oftenSkipped('B'), isFalse); // дослушивали так же часто
      for (var i = 0; i < 5; i++) {
        lib.recordSkip(b);
      }
      expect(lib.oftenSkipped('B'), isTrue);
    });

    test('сессия радио: заблокирован после двух пропусков без прослушиваний', () {
      final s = RadioSession();
      final x = t('zvuk', '1', 'X', 'a');
      s.skip(x);
      expect(s.blocked('X'), isFalse);
      s.skip(x);
      expect(s.blocked('X'), isTrue);
      s.play(x);
      s.play(x);
      expect(s.blocked('X'), isFalse);
      expect(s.liked, isEmpty); // дослушали столько же, сколько пропустили
      s.play(x);
      expect(s.liked, ['X']);
    });
  });

  group('Теги', () {
    test('нормализация: синонимы, мусор, родительские жанры, составные жанры', () {
      final t = TagService.normalize({'Deathcore': 1.0, 'seen live': 1.0, 'Hip Hop': 0.5, 'Metal/Hard Rock': 0.8, 'металкор': 0.7});
      expect(t.containsKey('seen live'), isFalse);
      expect(t['deathcore'], 1.0);
      expect(t['metal'], greaterThan(0.5)); // родитель deathcore и часть «Metal/Hard Rock»
      expect(t['hip-hop'], 0.5);
      expect(t['hard rock'], 0.8);
      expect(t['metalcore'], 0.7); // жанр Звука по-русски
    });

    test('похожесть: одно и то же — 1, ничего общего — 0, общий жанр — почти ничего', () {
      final k = TagService.normalize({'k-pop': 1.0});
      expect(TagService.similarity(k, k), closeTo(1, 1e-9));
      final d = TagService.normalize({'deathcore': 1.0});
      expect(TagService.similarity(d, d), greaterThan(0.7));
      expect(TagService.similarity(d, k), 0);
      expect(TagService.similarity(d, const {}), 0);
      // у LAZZY2WICE и у Tame Impala одинаково «alternative rock» — это не похожесть
      final seed = TagService.normalize({'alternative rock': 1.0, 'rap': 0.6, 'metal': 0.5});
      final tame = TagService.normalize({'alternative rock': 1.0, 'rock': 0.6});
      expect(TagService.similarity(seed, tame), lessThan(0.15));
    });

    test('радио по треку у любителя металла: тяжёлое выше, хотя песня — рэп', () async {
      Duration s(int x) => Duration(seconds: x);
      final lib = Library.memory();
      for (var i = 0; i < 6; i++) {
        lib.recordPlay(t('zvuk', 'm$i', 'Metal Band', 'x$i'));
      }
      final station = [
        for (var i = 0; i < 6; i++) t('soundcloud', 'r$i', 'Rapper$i', 'rap song $i', duration: s(150)),
        for (var i = 0; i < 6; i++) t('soundcloud', 'h$i', 'Heavy$i', 'heavy song $i', duration: s(200)),
      ];
      final seedSc = t('soundcloud', 'seed', 'Seed', 'Seed - Song', duration: s(160));
      final sc = FakeSoundCloud(results: {'Seed Song': [seedSc]}, stationTracks: station);
      final fakeTags = FakeTags({
        'metal band': {'deathcore': 1.0},
        'seed': {'emo rap': 1.0},
        for (var i = 0; i < 6; i++) 'rapper$i': {'hip-hop': 1.0},
        for (var i = 0; i < 6; i++) 'heavy$i': {'deathcore': 1.0, 'emo rap': 0.4},
      });
      final search = SearchService([sc]);
      final r = Recommendations(search, lib, CatalogService(search), graph: FakeGraph(), tags: fakeTags);
      final seed = t('zvuk', 'z', 'Seed', 'Song', duration: s(160));
      final batch = await r.radioBatch(RadioSeed.track(seed), {seed.key}, want: 6);
      final heavy = batch.where((x) => x.artist.startsWith('Heavy')).length;
      expect(heavy, greaterThanOrEqualTo(4));
      expect(batch.take(2).every((x) => x.artist.startsWith('Heavy')), isTrue);
    });
  });

  test('защита сайта от ботов (VPN) описывается понятно', () {
    final m = Net.describe(Exception('ClientRedirect loop detected, uri=https://zvuk.com/api/tiny/profile'));
    expect(m, contains('VPN'));
    expect(Net.describe(Exception('Звук: не удалось получить гостевой доступ (HTTP 418)')), contains('VPN'));
  });

  group('Порядок выдачи поиска', () {
    TrackGroup g(List<Track> v) => TrackGroup(v);
    test('все слова запроса и несколько площадок — выше, ремикс — ниже', () {
      final remix = g([t('soundcloud', '1', 'DJ X', 'Кино Группа крови remix')]);
      final other = g([t('soundcloud', '2', 'Кто-то', 'Песня про кровь')]);
      final real = g([t('zvuk', '3', 'Кино', 'Группа крови'), t('soundcloud', '4', 'Кино', 'Группа крови')]);
      final r = rank('кино группа крови', [remix, other, real]);
      expect(r.first, real);
      expect(r.last, other);
    });

    test('ремикс выше, если его и искали; пустой запрос не меняет порядок', () {
      final remix = g([t('soundcloud', '1', 'Кино', 'Группа крови remix')]);
      final real = g([t('zvuk', '3', 'Кино', 'Группа крови')]);
      expect(rank('кино группа крови remix', [real, remix]).first, remix);
      expect(rank('', [remix, real]).first, remix);
    });

    test('равные по смыслу сохраняют порядок площадок', () {
      final a = g([t('zvuk', '1', 'A', 'Song one')]);
      final b = g([t('soundcloud', '2', 'A', 'Song two')]);
      expect(rank('a song', [a, b]), [a, b]);
      expect(rank('a song', [b, a]), [b, a]);
    });
  });

  group('Синхронизация: слияние', () {
    Map<String, dynamic> pl(String id, String name, List<String> ids) => {
          'id': id,
          'name': name,
          'tracks': [for (final i in ids) t('zvuk', i, 'A', 'T$i').toJson()],
        };

    test('у плейлиста побеждает более свежая версия, новые с обеих сторон сохраняются', () {
      final a = {
        'playlists': [pl('liked', 'Любимое', ['1']), pl('p1', 'Старое имя', ['1'])],
        'stamps': {'pl:liked': 100, 'pl:p1': 100},
      };
      final b = {
        'playlists': [pl('liked', 'Любимое', ['1', '2']), pl('p1', 'Новое имя', ['3']), pl('p2', 'С телефона', [])],
        'stamps': {'pl:liked': 200, 'pl:p1': 300, 'pl:p2': 50},
      };
      final m = Library.merge(a, b);
      final names = [for (final p in m['playlists']) p['name']];
      expect(names, ['Любимое', 'Новое имя', 'С телефона']);
      expect((m['playlists'][0]['tracks'] as List).length, 2);
      expect(Library.merge(b, a)['playlists'].length, 3);
    });

    test('удалённый плейлист не возвращается, а изменённый после удаления — остаётся', () {
      final a = {
        'playlists': [pl('p1', 'X', [])],
        'stamps': {'pl:p1': 100},
      };
      final b = {'playlists': [], 'deleted': {'p1': 200}};
      expect(Library.merge(a, b)['playlists'], isEmpty);
      expect(Library.merge(b, a)['playlists'], isEmpty);
      final edited = {
        'playlists': [pl('p1', 'X', ['9'])],
        'stamps': {'pl:p1': 300},
      };
      expect(Library.merge(edited, b)['playlists'].length, 1);
    });

    test('«Любимое» не удаляется никогда', () {
      final a = {'playlists': [pl('liked', 'Любимое', [])]};
      final b = {'playlists': [], 'deleted': {'liked': 999}};
      expect(Library.merge(a, b)['playlists'].length, 1);
    });

    test('история объединяется по времени, без повторов', () {
      final x = t('zvuk', '1', 'A', 'x').toJson(), y = t('zvuk', '2', 'A', 'y').toJson();
      final z = t('zvuk', '3', 'A', 'z').toJson();
      final a = {
        'history': [x, y],
        'historyAt': {'zvuk:1': 10, 'zvuk:2': 30},
      };
      final b = {
        'history': [z, x],
        'historyAt': {'zvuk:3': 20, 'zvuk:1': 40},
      };
      final m = Library.merge(a, b);
      expect([for (final h in m['history']) h['id']], ['1', '2', '3']);
      expect(m['historyAt']['zvuk:1'], 40);
    });

    test('счётчики исполнителей — по максимуму', () {
      final a = {
        'artists': {
          'a': {'n': 'A', 'p': 5, 's': 1, 't': 10},
        },
      };
      final b = {
        'artists': {
          'a': {'n': 'A', 'p': 3, 's': 4, 't': 20},
          'b': {'n': 'B', 'p': 1, 's': 0, 't': 5},
        },
      };
      final m = Library.merge(a, b)['artists'];
      expect(m['a'], {'n': 'A', 'p': 5, 's': 4, 't': 20});
      expect(m['b']['p'], 1);
    });

    test('мусор из облака не роняет слияние', () {
      final m = Library.merge({'playlists': 'oops', 'stamps': 5, 'history': null}, {'artists': []});
      expect(m['playlists'], isEmpty);
      expect(m['history'], isEmpty);
    });

    test('библиотека → JSON → слияние с пустым облаком → то же самое; replaceWith восстанавливает', () async {
      final lib = Library.memory();
      final p = lib.createPlaylist('Моё');
      lib.addTo(p, t('zvuk', '1', 'A', 'x'));
      lib.toggleLike(t('zvuk', '2', 'B', 'y'));
      lib.addHistory(t('zvuk', '3', 'C', 'z'));
      lib.recordPlay(t('zvuk', '3', 'C', 'z'));
      final j = lib.toJson();
      final m = Library.merge(j, const {});
      expect(SyncService.canonical(m), SyncService.canonical(j));

      final other = Library.memory()..replaceWith(m);
      expect(SyncService.canonical(other.toJson()), SyncService.canonical(j));
      expect(other.playlists.map((p) => p.name), ['Любимое', 'Моё']);
      expect(other.artists['c']?.plays, 1);
    });

    test('сравнение не зависит от порядка ключей (база их переставляет)', () {
      expect(SyncService.canonical({'b': 1, 'a': [{'y': 2.0, 'x': 1}]}),
          SyncService.canonical({'a': [{'x': 1, 'y': 2}], 'b': 1}));
    });
  });
}
