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

  /// Что уже было в этом радио (ключи песен, см. [Recommendations.songKey]) — без повторов и перезаливов.
  final Set<String> seen = {};

  /// Ключи треков из очереди плеера.
  final Set<String> excluded = {};

  /// Запас кандидатов на следующие порции.
  final List<Track> pool = [];
  int fills = 0;

  /// Дослушанные треки — от их станций радио «дрейфует» дальше.
  final List<Track> good = [];
  final Set<String> _usedStations = {};

  void play(Track t) {
    _bump(played, t);
    if (!t.isPick) good.add(t);
  }

  void skip(Track t) => _bump(skipped, t);
  void _bump(Map<String, int> m, Track t) {
    final artist = Recommendations.trueArtist(t);
    final k = Library.artistKey(artist);
    if (k.isEmpty) return;
    m[k] = (m[k] ?? 0) + 1;
    names[k] = artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();
  }

  /// Трек для следующей станции: недавно дослушанный, ещё не использованный.
  Track? nextStationSeed(Random rnd) {
    final fresh = good.where((t) => !_usedStations.contains(t.key)).toList();
    if (fresh.isEmpty) return null;
    final t = fresh[fresh.length - 1 - rnd.nextInt(min(3, fresh.length))];
    _usedStations.add(t.key);
    return t;
  }

  /// Исполнителя пропустили дважды и больше, чем дослушали, — в этом радио его больше не ставим.
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
  //
  // Как устроено (так же делают большие сервисы — смесь «соседей по прослушиваниям» и твоих сигналов):
  // 1. Станция трека SoundCloud — что слушают те, кто слушает эту песню. Андерграунд живёт там,
  //    и это лучший источник «похожего» для него.
  // 2. Граф вкусов Deezer — похожие исполнители и их песни (только если исполнитель подтверждён
  //    по самой песне: у однофамильцев чужие «похожие»).
  // 3. По ходу радио — станции треков, которые ты дослушал, и похожие на дослушанных исполнителей.
  // Ограничения: тот же исполнитель — не больше четверти порции, без перезаливов одной песни,
  // ремиксов, минусовок, speed up, DJ-сетов и того, что ты пропускаешь или скрыл.

  static final _dash = RegExp(r'\s[-–—]\s');

  /// Настоящий исполнитель: на SoundCloud песню часто заливают другие люди как
  /// «Исполнитель - Название» — тогда исполнитель в названии, а не в имени загрузившего.
  static String trueArtist(Track t) {
    final m = _dash.firstMatch(t.title);
    if (t.source == 'soundcloud' && m != null && m.start > 0) return t.title.substring(0, m.start).trim();
    return t.artist;
  }

  /// Ключ песни, одинаковый у всех перезаливов: исполнитель + название без пометок.
  static String songKey(Track t) {
    var title = t.title;
    final m = _dash.firstMatch(title);
    if (t.source == 'soundcloud' && m != null && m.start > 0) title = title.substring(m.end);
    return '${Library.artistKey(trueArtist(t))}|${Track.normalize(LyricsService.cleanTitle(title))}';
  }

  /// Ключ по одному названию: перезаливы чужими людьми без имени исполнителя в названии
  /// («noname — гугл диск») иначе не узнать.
  static String titleKey(Track t) {
    var title = t.title;
    final m = _dash.firstMatch(title);
    if (t.source == 'soundcloud' && m != null && m.start > 0) title = title.substring(m.end);
    return 't|${Track.normalize(LyricsService.cleanTitle(title))}';
  }

  static bool _seen(RadioSession s, Track t) => s.seen.contains(songKey(t)) || s.seen.contains(titleKey(t));
  static bool _markSeen(RadioSession s, Track t) {
    if (_seen(s, t)) return false;
    s.seen
      ..add(songKey(t))
      ..add(titleKey(t));
    return true;
  }

  /// Годится ли трек для радио вообще (без учёта повторов).
  bool _fits(Track t, RadioSeed seed, RadioSession session) {
    if (t.previewOnly || t.isVideo) return false;
    final artist = trueArtist(t);
    if (!library.allowedInRecs(t) || library.dislikedArtists.contains(Library.artistKey(artist))) return false;
    if (session.blocked(artist) || library.oftenSkipped(artist)) return false;
    final seedTitle = (seed.track?.title ?? '').toLowerCase();
    for (final m in _otherCut.allMatches(t.title)) {
      if (!seedTitle.contains(m[0]!.toLowerCase())) return false;
    }
    final d = t.duration;
    if (d != null && d > Duration.zero && (d < const Duration(seconds: 50) || d > const Duration(minutes: 9))) {
      return false; // обрывки и DJ-сеты
    }
    return true;
  }

  final Map<String, Track?> _twins = {};

  /// Та же песня на SoundCloud (там у неё есть станция).
  Future<Track?> _scTwin(Track t) async {
    if (t.source == 'soundcloud') return t;
    final sc = search.sources.where((s) => s.id == 'soundcloud' && s.isConfigured).firstOrNull;
    if (sc == null) return null;
    final k = songKey(t);
    if (_twins.containsKey(k)) return _twins[k];
    final (artists, title) = CatalogService.matchKeys(t);
    final primary = trueArtist(t).split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();
    final found = await _safe(() => sc.search('$primary ${LyricsService.cleanTitle(t.title)}'));
    Track? best;
    for (final v in found) {
      if (!CatalogService.sameSong(v, artists, title) || !_sameCut(t, v)) continue;
      // загружено самим исполнителем — лучше перезалива
      if (Track.normalize(v.artist) == Track.normalize(primary)) {
        best = v;
        break;
      }
      best ??= v;
    }
    _twins[k] = best;
    return best;
  }

  /// Станция трека на SoundCloud.
  Future<List<Track>> _station(Track? t) async {
    if (t == null) return [];
    final twin = await _scTwin(t);
    if (twin == null) return [];
    final sc = search.sourceOf(twin);
    return _safe(() => sc.station(twin));
  }

  /// Исполнитель в графе: сначала по самой песне (надёжно), иначе по имени.
  Future<TasteArtist?> _graphArtist(String artist, {String? title}) async {
    try {
      if (title != null) {
        final a =
            await graph.artistForTrack(artist, LyricsService.cleanTitle(title)).timeout(const Duration(seconds: 10));
        if (a != null) return a;
      }
      return await graph.findArtist(artist).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  static Future<List<Track>> _none() async => const <Track>[];

  /// Пополнить запас кандидатов радио.
  Future<void> _refill(RadioSeed seed, RadioSession session) async {
    final first = session.fills == 0;
    session.fills++;
    final parts = <Future<List<Track>>>[];
    switch (seed.kind) {
      case RadioKind.track:
        final seedTrack = seed.track!;
        if (first) {
          final a = await _graphArtist(trueArtist(seedTrack), title: seedTrack.title);
          parts
            ..add(_station(seedTrack))
            ..add(a == null ? _none() : _safe(() => graph.artistRadio(a.id)))
            ..add(a == null ? _none() : _relatedTopsOf(a, artists: 4, perArtist: 2));
        } else {
          // дрейф: от того, что в этом радио дослушали
          parts.add(_station(session.nextStationSeed(_rnd) ?? seedTrack));
          final liked = session.liked..shuffle(_rnd);
          parts.add(_graphRadio(liked.isNotEmpty ? liked.first : trueArtist(seedTrack)));
        }
      case RadioKind.artist:
        final a = await _graphArtist(seed.artist, title: seed.track?.title);
        parts
          ..add(a == null ? _none() : _safe(() => graph.artistTop(a.id, limit: 25)))
          ..add(a == null ? _none() : _safe(() => graph.artistRadio(a.id)))
          ..add(_station(first ? seed.track : session.nextStationSeed(_rnd) ?? seed.track))
          ..add(first ? _artistTracks(seed.artist, sample: seed.track) : _none());
      case RadioKind.wave:
        final top = library.topArtists(10);
        final bases = <String>[];
        // любимые чаще, но не только первый: волна должна быть разной
        final w = [for (var i = 0; i < top.length; i++) (top[i], 1.0 / (i + 1))];
        for (var k = 0; k < 2 && w.isNotEmpty; k++) {
          final total = w.fold<double>(0, (s, e) => s + e.$2);
          var x = _rnd.nextDouble() * total;
          final i = w.indexWhere((e) => (x -= e.$2) <= 0);
          bases.add(w.removeAt(i < 0 ? 0 : i).$1);
        }
        final liked = session.liked..shuffle(_rnd);
        if (liked.isNotEmpty && !bases.contains(liked.first)) bases.add(liked.first);
        if (bases.isEmpty) {
          parts.add(_safe(graph.chart)); // волна без истории — популярное
        } else {
          for (final b in bases) {
            parts.add(_graphRadio(b));
          }
          // станция одной из песен любимых исполнителей (из истории или лайков)
          final keys = {for (final b in bases) Library.artistKey(b)};
          final mine = [...library.history, ...library.liked.tracks]
              .where((t) => !t.isPick && keys.contains(Library.artistKey(trueArtist(t))))
              .toList();
          parts.add(_station(session.nextStationSeed(_rnd) ?? (mine.isEmpty ? null : mine[_rnd.nextInt(mine.length)])));
        }
    }
    final lists = [for (final l in await Future.wait(parts)) List.of(l)..shuffle(_rnd)];
    // источники чередуем, чтобы ни один не забивал радио
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final l in lists) {
        if (i < l.length && !_seen(session, l[i])) session.pool.add(l[i]);
      }
    }
  }

  /// Следующая порция радио: готовые к воспроизведению треки (уже найденные на площадках).
  Future<List<Track>> radioBatch(RadioSeed seed, Set<String> exclude, {RadioSession? session, int want = 10}) async {
    session ??= RadioSession();
    if (seed.kind == RadioKind.track && seed.track == null) return [];
    if (seed.track != null) _markSeen(session, seed.track!);
    session.excluded.addAll(exclude);
    final seedArtist = seed.kind == RadioKind.wave ? '' : Library.artistKey(seed.artist);
    // сколько песен самого исполнителя в порции
    final ownMax = switch (seed.kind) {
      RadioKind.artist => (want / 2).ceil(),
      RadioKind.track => max(2, want ~/ 4),
      RadioKind.wave => 2,
    };

    final out = <Track>[];
    final perArtist = <String, int>{};
    for (var round = 0; round < 3 && out.length < want; round++) {
      if (session.pool.length < want * 2 && session.fills < 6) await _refill(seed, session);
      // кандидаты с учётом лимитов; подсказки потом ищем на площадках
      final cand = <Track>[];
      final keep = <Track>[];
      for (final t in session.pool) {
        if (cand.length >= (want - out.length) * 2) {
          keep.add(t);
          continue;
        }
        if (_seen(session, t) ||
            session.excluded.contains(t.key) ||
            session.excluded.contains(t.matchKey) ||
            !_fits(t, seed, session)) {
          continue;
        }
        final a = Library.artistKey(trueArtist(t));
        final limit = a == seedArtist ? ownMax : 2;
        if ((perArtist[a] ?? 0) >= limit) {
          keep.add(t); // пригодится в следующих порциях
          continue;
        }
        perArtist[a] = (perArtist[a] ?? 0) + 1;
        cand.add(t);
      }
      session.pool
        ..clear()
        ..addAll(keep);
      for (var i = 0; i < cand.length && out.length < want; i += 5) {
        final got = await Future.wait(cand.skip(i).take(5).map(resolve));
        for (final t in got) {
          if (t == null || out.length >= want || !_fits(t, seed, session)) continue;
          if (session.excluded.contains(t.key)) continue;
          if (_markSeen(session, t)) out.add(t);
        }
      }
      if (cand.isEmpty && session.fills >= 6) break;
    }

    if (out.length < want ~/ 2) {
      // ни станции, ни графа (нет сети, совсем нишевая песня) — запасной путь
      for (final t in await _fallbackBatch(seed)) {
        if (out.length >= want) break;
        if (_fits(t, seed, session) && !session.excluded.contains(t.key) && _markSeen(session, t)) {
          out.add(t);
        }
      }
    }
    return _spread(out);
  }

  Future<List<Track>> _relatedTopsOf(TasteArtist a, {int artists = 4, int perArtist = 2}) => _safe(() async {
        final rel = (await graph.related(a.id)).where((r) => !library.oftenSkipped(r.name)).toList();
        final pick = (rel.take(10).toList()..shuffle(_rnd)).take(artists).toList();
        final tops = await Future.wait(pick.map((r) => _safe(() => graph.artistTop(r.id, limit: 8))));
        return [for (final t in tops) ...(t..shuffle(_rnd)).take(perArtist)];
      });

  Future<List<Track>> _fallbackBatch(RadioSeed seed) async {
    final sample = seed.track;
    final results = await Future.wait([
      sample == null ? _none() : similar(sample),
      if (seed.kind != RadioKind.wave) _artistTracks(seed.artist, sample: sample),
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
      final last = out.isEmpty ? '' : Library.artistKey(trueArtist(out.last));
      final i = rest.indexWhere((t) => Library.artistKey(trueArtist(t)) != last);
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
        for (final s in seeds) _fallbackBatch(RadioSeed.track(s)),
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
