import '../models/track.dart';
import 'catalog.dart';
import 'library.dart';
import 'search_service.dart';

class RecSection {
  final String title;
  final String? subtitle;
  final List<Track> tracks;
  RecSection(this.title, this.tracks, {this.subtitle});
}

/// Рекомендации: похожие треки от площадок,
/// подобранные по истории прослушиваний.
class Recommendations {
  final SearchService search;
  final Library library;
  final CatalogService catalog;
  Recommendations(this.search, this.library, this.catalog);

  /// Похожие на трек по версии площадок. Если площадка трека не умеет (Звук, YouTube, Audiomack),
  /// находим ту же песню там, где умеют (SoundCloud), и берём похожие оттуда.
  Future<List<Track>> similar(Track t) async {
    final own = await _safe(() => search.sourceOf(t).similar(t));
    if (own.isNotEmpty) return own;
    for (final s in search.sources.where((s) => s.isConfigured && s.id != t.source && s.id == 'soundcloud')) {
      final found = await _safe(() => s.search('${t.artist} ${t.title}'));
      // только та же песня: «первый попавшийся» результат давал радио по чужой музыке
      final match = found.where((f) => f.matchKey == t.matchKey).firstOrNull;
      if (match == null) continue;
      final sim = await _safe(() => s.similar(match));
      if (sim.isNotEmpty) return sim;
    }
    return [];
  }

  /// Порция радио по треку. Смесь, поэтому радио работает с любой песни:
  /// похожие от площадок + другие треки исполнителя (страница исполнителя, а если её нет — поиск по имени).
  Future<List<Track>> radioBatch(Track seed, Set<String> exclude) async {
    final results = await Future.wait([similar(seed), _artistTracks(seed)]);
    final sim = results[0].take(15).toList();
    // если площадки не дали «похожих», больше берём у исполнителя
    final art = (results[1]..shuffle()).take(sim.isEmpty ? 12 : 5).toList();

    // чередуем: два похожих, один исполнителя
    final mix = <Track>[];
    var i = 0, a = 0;
    while (i < sim.length || a < art.length) {
      for (var k = 0; k < 2 && i < sim.length; k++) {
        mix.add(sim[i++]);
      }
      if (a < art.length) mix.add(art[a++]);
    }

    final seen = <String>{...exclude, seed.key, seed.matchKey};
    return [
      for (final t in mix)
        // без превью и видео — радио должно играть само, без экрана; без того, что «не нравится»
        if (!t.previewOnly && !t.isVideo && library.allowedInRecs(t) && seen.add(t.key) && seen.add(t.matchKey)) t
    ];
  }

  Future<List<Track>> _artistTracks(Track seed) async {
    try {
      final a = await catalog.artistFor(seed).timeout(const Duration(seconds: 12));
      if (a != null && a.topTracks.isNotEmpty) return a.topTracks.toList();
    } catch (_) {}
    // страницы исполнителя нет — ищем его треки по имени на всех площадках (без YouTube)
    final name = Library.artistKey(seed.artist);
    if (name.isEmpty) return [];
    try {
      final r = await search.search(seed.artist.split(',').first.trim(), includeVideo: false);
      return [
        for (final g in r.groups)
          if (Library.artistKey(g.main.artist) == name) g.main
      ];
    } catch (_) {
      return [];
    }
  }

  List<RecSection>? _cache;
  DateTime? _cacheAt;

  /// Подборки для главной. Результат держим 20 минут, чтобы не скачивать всё заново
  /// при каждом открытии; [force] — обновить (кнопка и «потянуть вниз»).
  /// Сбросить подборки главной (например, после «Не нравится»).
  void invalidate() => _cache = null;

  Future<List<RecSection>> forYou({bool force = false}) async {
    if (!force && _cache != null && DateTime.now().difference(_cacheAt!) < const Duration(minutes: 20)) {
      return _cache!;
    }
    final result = [
      // убираем то, что «не нравится» (и его исполнителей); пустые подборки — тоже
      for (final s in await _buildForYou())
        if (s.tracks.where(library.allowedInRecs).isNotEmpty)
          RecSection(s.title, s.tracks.where(library.allowedInRecs).toList(), subtitle: s.subtitle),
    ];
    _cache = result;
    _cacheAt = DateTime.now();
    return result;
  }

  Future<List<RecSection>> _buildForYou() async {
    final sections = <RecSection>[];
    final futures = <Future<void>>[];


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

    // порядок: по свежести истории
    sections.sort((a, b) {
      final ia = seeds.indexWhere((s) => a.subtitle == s.artist);
      final ib = seeds.indexWhere((s) => b.subtitle == s.artist);
      return ia.compareTo(ib);
    });

    if (library.history.isNotEmpty) {
      sections.add(RecSection('Недавно слушал', library.history.take(20).toList()));
    }
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
