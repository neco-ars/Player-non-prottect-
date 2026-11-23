import 'dart:math';

import '../models/track.dart';
import 'catalog.dart';
import 'library.dart';
import 'lyrics.dart';
import 'search_service.dart';
import 'taste.dart';

class RecSection {
  final String title;
  final String? subtitle;
  final List<Track> tracks;
  RecSection(this.title, this.tracks, {this.subtitle});
}

/// С чего началось радио.
enum RadioKind {
  /// по треку: исполнитель трека и похожие на него
  track,

  /// по исполнителю: больше его самого, но с похожими
  artist,

  /// «Моя волна»: по любимым исполнителям из истории, лайков и дослушанных треков
  wave,
}

class RadioSeed {
  final RadioKind kind;
  final Track? track;
  final String artist;
  const RadioSeed(this.kind, {this.track, this.artist = ''});

  factory RadioSeed.track(Track t) => RadioSeed(RadioKind.track, track: t, artist: t.artist);
  factory RadioSeed.artist(String name, {Track? sample}) => RadioSeed(RadioKind.artist, track: sample, artist: name);
  static const wave = RadioSeed(RadioKind.wave);

  String get title => switch (kind) {
        RadioKind.wave => 'Моя волна',
        RadioKind.artist => 'Радио: $artist',
        RadioKind.track => 'Радио по «${track?.title ?? artist}»',
      };
}

/// Что происходило в текущем радио: кого дослушали, кого пропустили.
/// Радио подстраивается на ходу, как «Моя волна».
class RadioSession {
  final Map<String, int> played = {}; // artistKey → дослушано
  final Map<String, int> skipped = {}; // artistKey → пропущено
  final Map<String, String> names = {};

  void play(Track t) => _bump(played, t);
  void skip(Track t) => _bump(skipped, t);
  void _bump(Map<String, int> m, Track t) {
    final k = Library.artistKey(t.artist);
    if (k.isEmpty) return;
    m[k] = (m[k] ?? 0) + 1;
    names[k] = t.artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();
  }

  /// Исполнителя пропустили дважды подряд больше, чем дослушали, — в этом радио его больше не ставим.
  bool blocked(String artist) {
    final k = Library.artistKey(artist);
    return (skipped[k] ?? 0) >= 2 && (skipped[k] ?? 0) > (played[k] ?? 0);
  }

  /// Кого в этом радио дослушивали — от них стоит взять ещё.
  List<String> get liked => [
        for (final e in played.entries)
          if (e.value > (skipped[e.key] ?? 0)) names[e.key]!,
      ];
}

/// Рекомендации и радио.
///
/// Откуда берутся: «граф вкусов» ([TasteGraph] — похожие исполнители и радио исполнителя
/// из открытого API Deezer) + твои сигналы: что дослушиваешь, что лайкаешь, что пропускаешь.
/// Найденные песни играют с наших площадок ([resolve]). Если граф недоступен — запасной путь:
/// «похожие» от SoundCloud и другие треки того же исполнителя.
class Recommendations {
  final SearchService search;
  final Library library;
  final CatalogService catalog;
  final TasteGraph graph;
  final Random _rnd;
  Recommendations(this.search, this.library, this.catalog, {TasteGraph? graph, Random? random})
      : graph = graph ?? TasteGraph(),
        _rnd = random ?? Random();

  // ---------- подсказка → играбельный трек ----------

  final Map<String, Track?> _resolved = {};

  /// Найти песню-подсказку ([Track.isPick]) на наших площадках. null — нигде нет полной версии.
  /// Берём ту же песню (тот же исполнитель и название) и по возможности той же длины:
  /// так не попадаются ремиксы, «speed up» и чужие каверы.
  Future<Track?> resolve(Track hint) async {
    if (!hint.isPick) return hint;
    final k = hint.matchKey;
    if (_resolved.containsKey(k)) return _resolved[k];
    final (artists, title) = CatalogService.matchKeys(hint);
    final primary = hint.artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();
    final SearchResult r;
    try {
      r = await search.search('$primary ${LyricsService.cleanTitle(hint.title)}', includeVideo: false);
    } catch (_) {
      return null;
    }
    final found = [
      for (final g in r.groups)
        for (final v in g.variants)
          if (!v.previewOnly && !v.isVideo && !v.isPick && CatalogService.sameSong(v, artists, title) && _sameCut(hint, v))
            v,
    ];
    Track? best;
    var bestScore = -1 << 30;
    for (final (i, v) in found.indexed) {
      var s = -i; // при прочих равных — как выдали площадки
      final d = hint.duration, vd = v.duration;
      if (d != null && vd != null) {
        final diff = (d - vd).inSeconds.abs();
        s += diff <= 8 ? 40 : (diff <= 25 ? 10 : -30);
      }
      if (v.explicit && (hint.explicit || TrackGroup.preferExplicit)) s += 20;
      if (Track.normalize(v.artist) == Track.normalize(primary)) s += 15; // загружено самим исполнителем
      if (v.source == 'local') s += 25;
      if (s > bestScore) {
        bestScore = s;
        best = v;
      }
    }
    // «не нашли» запоминаем, только если ответили все площадки
    if (best != null || r.errors.isEmpty) {
      _resolved[k] = best;
      if (_resolved.length > 500) _resolved.remove(_resolved.keys.first);
    }
    return best;
  }

  static final _otherCut = RegExp(
      r'instrumental|инструментал|минус|karaoke|караоке|remix|ремикс|\brmx\b|slowed|sped ?up|speed ?up|nightcore|'
      r'\bcover\b|кавер|\b8d\b|bass ?boost|reverb|mashup|мэшап|acapella|акапелла|\bedit\b|\bmix\b|перепевка',
      caseSensitive: false);

  /// Та же запись, а не ремикс, минусовка, «speed up» или кавер; длина почти совпадает.
  static bool _sameCut(Track hint, Track v) {
    for (final m in _otherCut.allMatches(v.title)) {
      if (!hint.title.toLowerCase().contains(m[0]!.toLowerCase())) return false;
    }
    final d = hint.duration, vd = v.duration;
    if (d != null && vd != null && d > Duration.zero && vd > Duration.zero) {
      if ((d - vd).inSeconds.abs() > 30) return false;
    }
    return true;
  }

  /// Найти на площадках до [want] треков из списка, по [parallel] поисков за раз.
  Future<List<Track>> resolveMany(List<Track> hints, int want, {int parallel = 4}) async {
    final out = <Track>[];
    final seen = <String>{};
    for (var i = 0; i < hints.length && out.length < want; i += parallel) {
      final chunk = hints.skip(i).take(parallel).toList();
      final got = await Future.wait(chunk.map(resolve));
      for (final t in got) {
        if (t != null && out.length < want && seen.add(t.key) && seen.add(t.matchKey)) out.add(t);
      }
    }
    return out;
  }

  // ---------- граф вкусов ----------

  /// Радио Deezer по исполнителю (по имени). Пусто, если исполнителя там нет или граф недоступен.
  Future<List<Track>> _graphRadio(String artist) => _safe(() async {
        final a = await graph.findArtist(artist);
        return a == null ? <Track>[] : graph.artistRadio(a.id);
      });

  Future<List<Track>> _graphTop(String artist, {int limit = 15}) => _safe(() async {
        final a = await graph.findArtist(artist);
        return a == null ? <Track>[] : graph.artistTop(a.id, limit: limit);
      });

  /// Популярные треки нескольких похожих исполнителей (по [perArtist] у каждого).
  Future<List<Track>> _relatedTops(String artist, {int artists = 4, int perArtist = 2, Set<String> skip = const {}}) =>
      _safe(() async {
        final a = await graph.findArtist(artist);
        if (a == null) return <Track>[];
        final rel = (await graph.related(a.id))
            .where((r) => !skip.contains(Library.artistKey(r.name)) && !library.oftenSkipped(r.name))
            .toList();
        // берём из первой десятки (самые похожие), но каждый раз разных
        final pick = (rel.take(10).toList()..shuffle(_rnd)).take(artists).toList();
        final tops = await Future.wait(pick.map((r) => _safe(() => graph.artistTop(r.id, limit: 8))));
        return [for (final t in tops) ...(t..shuffle(_rnd)).take(perArtist)];
      });

  // ---------- запасной путь (без графа) ----------

  /// Похожие на трек по версии площадок. Если площадка трека не умеет (Звук, YouTube, Audiomack),
  /// находим ту же песню там, где умеют (SoundCloud), и берём похожие оттуда.
  Future<List<Track>> similar(Track t) async {
    if (t.isPick) return [];
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

  Future<List<Track>> _artistTracks(String artist, {Track? sample}) async {
    if (sample != null && !sample.isPick) {
      try {
        final a = await catalog.artistFor(sample).timeout(const Duration(seconds: 12));
        if (a != null && a.topTracks.isNotEmpty) return a.topTracks.toList();
      } catch (_) {}
    }
    // страницы исполнителя нет — ищем его треки по имени на всех площадках (без YouTube)
    final name = Library.artistKey(artist);
    if (name.isEmpty) return [];
    try {
      final r = await search.search(artist.split(',').first.trim(), includeVideo: false);
      return [
        for (final g in r.groups)
          if (Library.artistKey(g.main.artist) == name) g.main
      ];
    } catch (_) {
      return [];
    }
  }

  // ---------- радио ----------

  /// Следующая порция радио: готовые к воспроизведению треки (уже найденные на площадках).
  Future<List<Track>> radioBatch(RadioSeed seed, Set<String> exclude, {RadioSession? session, int want = 10}) async {
    session ??= RadioSession();
    final ok = _filter(exclude, session);

    // от чьего имени подбираем эту порцию
    final bases = <String>[];
    switch (seed.kind) {
      case RadioKind.track:
      case RadioKind.artist:
        bases.add(seed.artist);
      case RadioKind.wave:
        final top = library.topArtists(10);
        // любимые чаще, но не только первый: волна должна быть разной
        final w = [for (var i = 0; i < top.length; i++) (top[i], 1.0 / (i + 1))];
        for (var k = 0; k < 2 && w.isNotEmpty; k++) {
          final total = w.fold<double>(0, (s, e) => s + e.$2);
          var x = _rnd.nextDouble() * total;
          final i = w.indexWhere((e) => (x -= e.$2) <= 0);
          bases.add(w.removeAt(i < 0 ? 0 : i).$1);
        }
    }
    // кого в этом радио дослушали — от того тоже
    final liked = session.liked.where((a) => !bases.contains(a)).toList()..shuffle(_rnd);
    if (liked.isNotEmpty) bases.add(liked.first);

    final hints = <Track>[];
    if (bases.isEmpty) {
      hints.addAll((await _safe(graph.chart))..shuffle(_rnd)); // волна без истории — популярное
    } else {
      final parts = await Future.wait([
        for (final b in bases) _graphRadio(b),
        if (seed.kind == RadioKind.artist) _graphTop(seed.artist, limit: 25),
        if (seed.kind != RadioKind.artist) _relatedTops(bases.first, artists: 3, perArtist: 2),
      ]);
      // радио исполнителя — больше его самого
      if (seed.kind == RadioKind.artist) {
        final own = parts.last..shuffle(_rnd);
        final radio = parts.first..shuffle(_rnd);
        hints.addAll(_alternate(own, radio, 1, 1));
      } else {
        for (final p in parts) {
          hints.addAll(p..shuffle(_rnd));
        }
        hints.shuffle(_rnd);
      }
    }

    var out = await resolveMany(_spread(_unique(hints.where(ok))), want);
    if (out.length < want ~/ 2) {
      // граф ничего не дал (нет исполнителя, нет сети до Deezer) — запасной путь
      final fallback = await _fallbackBatch(seed, bases);
      out = [...out, ...fallback];
    }
    return _spread(_unique(out.where(ok)).take(want).toList());
  }

  /// Подходит ли трек для этого радио.
  bool Function(Track) _filter(Set<String> exclude, RadioSession session) => (t) =>
      !t.previewOnly &&
      !t.isVideo &&
      library.allowedInRecs(t) &&
      !session.blocked(t.artist) &&
      !library.oftenSkipped(t.artist) &&
      !exclude.contains(t.key) &&
      !exclude.contains(t.matchKey);

  static List<Track> _unique(Iterable<Track> list) {
    final seen = <String>{};
    return [for (final t in list) if (seen.add(t.matchKey)) t];
  }

  Future<List<Track>> _fallbackBatch(RadioSeed seed, List<String> bases) async {
    final sample = seed.track;
    final results = await Future.wait([
      sample == null ? Future.value(<Track>[]) : similar(sample),
      for (final b in bases.take(2)) _artistTracks(b, sample: b == seed.artist ? sample : null),
    ]);
    final sim = results.first.take(15).toList();
    final art = [for (final r in results.skip(1)) ...r]..shuffle(_rnd);
    return _alternate(sim, art.take(sim.isEmpty ? 12 : 5).toList(), 2, 1);
  }

  /// Чередовать два списка: [na] из первого, [nb] из второго.
  static List<Track> _alternate(List<Track> a, List<Track> b, int na, int nb) {
    final out = <Track>[];
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      for (var k = 0; k < na && i < a.length; k++) {
        out.add(a[i++]);
      }
      for (var k = 0; k < nb && j < b.length; k++) {
        out.add(b[j++]);
      }
    }
    return out;
  }

  /// Не ставить один и тот же исполнитель подряд, если есть из кого выбрать.
  static List<Track> _spread(List<Track> list) {
    final rest = List.of(list);
    final out = <Track>[];
    while (rest.isNotEmpty) {
      final last = out.isEmpty ? '' : Library.artistKey(out.last.artist);
      final i = rest.indexWhere((t) => Library.artistKey(t.artist) != last);
      out.add(rest.removeAt(i < 0 ? 0 : i));
    }
    return out;
  }

  // ---------- главная ----------

  List<RecSection>? _cache;
  DateTime? _cacheAt;

  /// Сбросить подборки главной (например, после «Не нравится»).
  void invalidate() => _cache = null;

  /// Подборки для главной. Результат держим 20 минут, чтобы не скачивать всё заново
  /// при каждом открытии; [force] — обновить (кнопка и «потянуть вниз»).
  Future<List<RecSection>> forYou({bool force = false}) async {
    if (!force && _cache != null && DateTime.now().difference(_cacheAt!) < const Duration(minutes: 20)) {
      return _cache!;
    }
    bool ok(Track t) => library.allowedInRecs(t) && !library.oftenSkipped(t.artist);
    final result = [
      // убираем то, что «не нравится» (и его исполнителей); пустые подборки — тоже
      for (final s in await _buildForYou())
        if (s.tracks.where(ok).isNotEmpty) RecSection(s.title, s.tracks.where(ok).toList(), subtitle: s.subtitle),
    ];
    _cache = result;
    _cacheAt = DateTime.now();
    return result;
  }

  Future<List<RecSection>> _buildForYou() async {
    final top = library.topArtists(6);
    final known = {
      for (final t in library.history) Library.artistKey(t.artist),
      for (final t in library.liked.tracks) Library.artistKey(t.artist),
      ...library.artists.keys,
    };
    final recent = {for (final t in library.history.take(40)) t.matchKey};

    // «Похоже на …» — по трём любимым исполнителям: радио Deezer без самого исполнителя
    Future<RecSection?> like(String artist) async {
      final key = Library.artistKey(artist);
      final radio = (await _graphRadio(artist))
          .where((t) => Library.artistKey(t.artist) != key && !recent.contains(t.matchKey))
          .toList();
      if (radio.length < 5) return null;
      return RecSection('Похоже на $artist', _spread(radio).take(20).toList(), subtitle: 'Исполнители в том же духе');
    }

    // «Новое для тебя» — популярное у похожих исполнителей, которых ты ещё не слушал
    Future<RecSection?> fresh() async {
      final parts = await Future.wait([
        for (final a in top.take(4)) _relatedTops(a, artists: 3, perArtist: 2, skip: known),
      ]);
      final list = _spread(([for (final p in parts) ...p]..shuffle(_rnd)));
      final seen = <String>{};
      final out = [for (final t in list) if (seen.add(t.matchKey)) t].take(20).toList();
      return out.length < 4 ? null : RecSection('Новое для тебя', out, subtitle: 'Исполнители, которых ты ещё не слушал');
    }

    Future<RecSection?> chart() async {
      final c = await _safe(graph.chart);
      return c.isEmpty ? null : RecSection('Популярное сейчас', c.take(25).toList());
    }

    final built = await Future.wait([
      for (final a in top.take(3)) like(a),
      if (top.isNotEmpty) fresh(),
      // чарт Deezer — общемировой, поэтому только для тех, у кого ещё нет истории
      if (top.isEmpty) chart(),
    ]);
    final sections = built.whereType<RecSection>().toList();

    // граф недоступен — подборки по старинке: похожие и треки исполнителя с площадок
    if (sections.isEmpty && top.isNotEmpty) {
      final seeds = <Track>[];
      final artists = <String>{};
      for (final t in library.history) {
        if (artists.add(Library.artistKey(t.artist))) seeds.add(t);
        if (seeds.length == 3) break;
      }
      final old = await Future.wait([
        for (final s in seeds) _fallbackBatch(RadioSeed.track(s), [s.artist]),
      ]);
      for (final (i, s) in seeds.indexed) {
        final list = old[i].where((t) => !t.previewOnly && !t.isVideo).take(15).toList();
        if (list.isNotEmpty) sections.add(RecSection('Похоже на «${s.title}»', list, subtitle: s.artist));
      }
    }

    if (library.history.isNotEmpty) {
      sections.add(RecSection('Недавно слушал', library.history.take(20).toList()));
    }
    // давно не включал любимое
    final old = library.liked.tracks.where((t) => !recent.contains(t.matchKey)).toList()..shuffle(_rnd);
    if (old.length >= 6) sections.add(RecSection('Из любимого', old.take(20).toList()));
    return sections;
  }

  static Future<List<Track>> _safe(Future<List<Track>> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 12));
    } catch (_) {
      return [];
    }
  }
}
