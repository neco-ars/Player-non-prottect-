import '../models/track.dart';
import '../sources/audius.dart';
import '../sources/yandex.dart';
import 'catalog.dart';
import 'library.dart';
import 'search_service.dart';

class RecSection {
  final String title;
  final String? subtitle;
  final List<Track> tracks;
  RecSection(this.title, this.tracks, {this.subtitle});
}

/// Рекомендации: «Моя волна» Яндекса и похожие треки от площадок,
/// подобранные по истории прослушиваний.
class Recommendations {
  final SearchService search;
  final Library library;
  final YandexSource yandex;
  final AudiusSource audius;
  final CatalogService catalog;
  Recommendations(this.search, this.library, this.yandex, this.audius, this.catalog);

  /// Похожие на трек по версии площадок. Если площадка трека не умеет (Звук, Audius, YouTube),
  /// находим ту же песню там, где умеют (Яндекс, SoundCloud), и берём похожие оттуда.
  Future<List<Track>> similar(Track t) async {
    final own = await _safe(() => search.sourceOf(t).similar(t));
    if (own.isNotEmpty) return own;
    for (final s in search.sources.where((s) => s.isConfigured && s.id != t.source && (s.id == 'yandex' || s.id == 'soundcloud'))) {
      final found = await _safe(() => s.search('${t.artist} ${t.title}'));
      // только та же песня: «первый попавшийся» результат давал радио по чужой музыке
      final match = found.where((f) => f.matchKey == t.matchKey).firstOrNull;
      if (match == null) continue;
      final sim = await _safe(() => s.similar(match));
      if (sim.isNotEmpty) return sim;
    }
    return [];
  }

  /// Порция радио по треку. Смесь из трёх источников, поэтому радио работает с любой песни:
  /// похожие от площадок + другие треки исполнителя + тренды жанра.
  Future<List<Track>> radioBatch(Track seed, Set<String> exclude) async {
    final results = await Future.wait([
      similar(seed),
      _artistTracks(seed),
      _safe(() => audius.trending(genre: _audiusGenre(seed.genre))),
    ]);
    final similarList = results[0];
    final artistList = results[1]..shuffle();
    final genreList = results[2]..shuffle();

    // если площадки не дали «похожих», больше берём у исполнителя и из жанра
    final mix = <Track>[];
    final sim = similarList.take(15).toList();
    final art = artistList.take(sim.isEmpty ? 8 : 4).toList();
    final gen = genreList.take(sim.isEmpty ? 8 : 4).toList();
    // чередуем: два похожих, один исполнителя, один из жанра
    var i = 0, a = 0, g = 0;
    while (i < sim.length || a < art.length || g < gen.length) {
      for (var k = 0; k < 2 && i < sim.length; k++) {
        mix.add(sim[i++]);
      }
      if (a < art.length) mix.add(art[a++]);
      if (g < gen.length) mix.add(gen[g++]);
    }

    final seen = <String>{...exclude, seed.key, seed.matchKey};
    return [
      for (final t in mix)
        // без превью и видео — радио должно играть само, без экрана
        if (!t.previewOnly && !t.isVideo && seen.add(t.key) && seen.add(t.matchKey)) t
    ];
  }

  Future<List<Track>> _artistTracks(Track seed) async {
    try {
      final a = await catalog.artistFor(seed).timeout(const Duration(seconds: 12));
      return a?.topTracks.toList() ?? [];
    } catch (_) {
      return [];
    }
  }

  /// Жанры площадок → жанры Audius (там свой список).
  static String? _audiusGenre(String? g) {
    final s = g?.toLowerCase() ?? '';
    if (s.isEmpty) return null;
    if (s.contains('rap') || s.contains('hip') || s.contains('рэп') || s.contains('хип')) return 'Hip-Hop/Rap';
    if (s.contains('phonk') || s.contains('trap')) return 'Trap';
    if (s.contains('electr') || s.contains('house') || s.contains('techno')) return 'Electronic';
    if (s.contains('rock') || s.contains('рок')) return 'Rock';
    if (s.contains('pop') || s.contains('поп')) return 'Pop';
    if (s.contains('r&b') || s.contains('rnb') || s.contains('soul')) return 'R&B/Soul';
    if (s.contains('lofi') || s.contains('lo-fi')) return 'Lo-Fi';
    return null;
  }

  List<RecSection>? _cache;
  DateTime? _cacheAt;

  /// Подборки для главной. Результат держим 20 минут, чтобы не скачивать всё заново
  /// при каждом открытии; [force] — обновить (кнопка и «потянуть вниз»).
  Future<List<RecSection>> forYou({bool force = false}) async {
    if (!force && _cache != null && DateTime.now().difference(_cacheAt!) < const Duration(minutes: 20)) {
      return _cache!;
    }
    final result = await _buildForYou();
    _cache = result;
    _cacheAt = DateTime.now();
    return result;
  }

  Future<List<RecSection>> _buildForYou() async {
    final sections = <RecSection>[];
    final futures = <Future<void>>[];
    // тренды запускаем сразу, параллельно с остальным
    final trendingF = _safe(() => audius.trending());
    final rapF = _safe(() => audius.trending(genre: 'Hip-Hop/Rap'));

    if (yandex.isConfigured) {
      futures.add(_safe(yandex.myWave).then((w) {
        if (w.isNotEmpty) sections.add(RecSection('Моя волна', w, subtitle: 'Яндекс Музыка'));
      }));
    }

    // по трём последним разным исполнителям из истории
    final seeds = <Track>[];
    final artists = <String>{};
    for (final t in library.history) {
      if (artists.add(Track.normalize(t.artist))) seeds.add(t);
      if (seeds.length == 3) break;
    }
    for (final seed in seeds) {
      futures.add(radioBatch(seed, const {}).then((s) {
        final list = s.where((t) => !t.previewOnly).take(15).toList();
        if (list.isNotEmpty) sections.add(RecSection('Похоже на «${seed.title}»', list, subtitle: seed.artist));
      }));
    }
    await Future.wait(futures);

    // порядок: волна, потом в порядке свежести истории
    sections.sort((a, b) {
      if (a.title == 'Моя волна') return -1;
      if (b.title == 'Моя волна') return 1;
      final ia = seeds.indexWhere((s) => a.subtitle == s.artist);
      final ib = seeds.indexWhere((s) => b.subtitle == s.artist);
      return ia.compareTo(ib);
    });

    if (library.history.isNotEmpty) {
      sections.add(RecSection('Недавно слушал', library.history.take(20).toList()));
    }
    // тренды недели на Audius — всегда, чтобы главная не была пустой
    final trending = await trendingF;
    if (trending.isNotEmpty) sections.add(RecSection('В тренде', trending.take(20).toList(), subtitle: 'Audius'));
    final rap = await rapF;
    if (rap.isNotEmpty) sections.add(RecSection('Рэп в тренде', rap.take(20).toList(), subtitle: 'Audius'));
    return sections;
  }

  static Future<List<Track>> _safe(Future<List<Track>> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 10));
    } catch (_) {
      return [];
    }
  }
}
