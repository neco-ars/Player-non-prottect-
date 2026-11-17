import '../models/track.dart';
import '../sources/audius.dart';
import '../sources/yandex.dart';
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
  Recommendations(this.search, this.library, this.yandex, this.audius);

  /// Похожие на трек. Если площадка трека не умеет (YouTube),
  /// находим ту же песню там, где умеют, и берём похожие оттуда.
  Future<List<Track>> similar(Track t) async {
    final own = await _safe(() => search.sourceOf(t).similar(t));
    if (own.isNotEmpty) return own;
    // площадки, которые умеют «похожие»
    for (final s in search.sources.where((s) => s.isConfigured && s.id != t.source && (s.id == 'yandex' || s.id == 'soundcloud'))) {
      final found = await _safe(() => s.search('${t.artist} ${t.title}'));
      final match = found.where((f) => f.matchKey == t.matchKey).firstOrNull ?? found.firstOrNull;
      if (match == null) continue;
      final sim = await _safe(() => s.similar(match));
      if (sim.isNotEmpty) return sim;
    }
    // запасной вариант: другие треки этого исполнителя и тренды жанра на Audius
    final byArtist = await _safe(() => audius.search(t.artist));
    final genre = await _safe(() => audius.trending(genre: t.genre));
    return [...byArtist.where((x) => x != t), ...genre];
  }

  /// Бесконечное радио: следующая порция похожих, без уже звучавших.
  Future<List<Track>> radioBatch(Track seed, Set<String> exclude) async {
    final list = await similar(seed);
    final seen = <String>{...exclude};
    return [
      for (final t in list)
        if (!t.previewOnly && seen.add(t.key) && seen.add(t.matchKey)) t
    ];
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
      futures.add(similar(seed).then((s) {
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
