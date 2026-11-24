import 'dart:math';

import '../models/track.dart';
import 'catalog.dart';
import 'library.dart';
import 'lyrics.dart';
import '../sources/soundcloud.dart';
import 'search_service.dart';
import 'tags.dart';
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

  /// по тегу (жанру): «metalcore», «emo rap»…
  tag,
}

class RadioSeed {
  final RadioKind kind;
  final Track? track;

  /// Исполнитель (для радио по треку и исполнителю) или тег (для радио по тегу).
  final String artist;
  const RadioSeed(this.kind, {this.track, this.artist = ''});

  factory RadioSeed.track(Track t) => RadioSeed(RadioKind.track, track: t, artist: Recommendations.trueArtist(t));
  factory RadioSeed.artist(String name, {Track? sample}) => RadioSeed(RadioKind.artist, track: sample, artist: name);
  factory RadioSeed.tag(String tag) => RadioSeed(RadioKind.tag, artist: tag);
  static const wave = RadioSeed(RadioKind.wave);

  String get title => switch (kind) {
        RadioKind.wave => 'Моя волна',
        RadioKind.artist => 'Радио: $artist',
        RadioKind.track => 'Радио по «${track?.title ?? artist}»',
        RadioKind.tag => 'Радио: #$artist',
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

  /// Куда целится радио по тегам: смесь тегов стартовой песни и твоего профиля вкуса.
  Tags? target;

  /// Теги того, что ты пропускаешь и скрыл, — такое опускается вниз.
  Tags avoid = const {};

  /// Лайк или дизлайк изменил профиль: перед следующей порцией пересчитать цель.
  bool feedbackDirty = false;

  /// Теги стартовой песни (исполнителя, тега) и твоего профиля — по отдельности.
  Tags seedTags = const {};
  Tags like = const {};

  /// Доля «похоже на песню» в оценке (остальное — «похоже на твой вкус»).
  double seedWeight = 0.5;

  /// Отчёт «почему эти треки»: откуда сколько пришло и что отсеяно.
  final RadioReport report = RadioReport();

  /// Откуда кандидат: seed — источники, похожие на саму песню (станция, похожие исполнители),
  /// tag — поиск по тегам, drift — от того, что ты дослушал в этом радио.
  final Map<String, String> origin = {};

  /// Из какого источника пришёл кандидат (для отчёта).
  final Map<String, String> labels = {};

  /// Теги, по которым добираем кандидатов (сначала «мостики» между песней и твоим вкусом).
  List<String> sourceTags = const [];

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

/// Отчёт радио: сколько кандидатов дал каждый источник и сколько отсеял каждый фильтр.
class RadioReport {
  final Map<String, int> sources = {};
  final Map<String, int> dropped = {};
  int given = 0;

  /// Выданные треки: исполнитель — название | источник | теги | оценка.
  final List<String> items = [];
  List<String> lastTarget = const [], lastLike = const [], lastAvoid = const [], sourceTags = const [];

  void count(String why) => dropped[why] = (dropped[why] ?? 0) + 1;

  String text(RadioSeed? seed) {
    String list(Map<String, int> m) {
      final keys = m.keys.toList()..sort((a, b) => m[b]!.compareTo(m[a]!));
      return keys.isEmpty ? '  —' : keys.map((k) => '  $k: ${m[k]}').join('\n');
    }

    return [
      'Радио: ${seed?.title ?? '—'}',
      'Выдано треков: $given',
      'Теги песни: ${lastTarget.isEmpty ? 'нет' : lastTarget.join(', ')}',
      'Твой вкус: ${lastLike.isEmpty ? 'пока нет данных' : lastLike.join(', ')}',
      'Избегаешь: ${lastAvoid.isEmpty ? '—' : lastAvoid.join(', ')}',
      'Добор по тегам: ${sourceTags.isEmpty ? '—' : sourceTags.join(', ')}',
      'Источники (кандидатов):',
      list(sources),
      'Отсеяно:',
      list(dropped),
      'Треки (источник | теги | оценка):',
      if (items.isEmpty) '  —' else ...items.reversed.take(40).toList().reversed.map((x) => '  $x'),
    ].join('\n');
  }
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
  final TagService tags;
  final Random _rnd;
  Recommendations(this.search, this.library, this.catalog, {TasteGraph? graph, TagService? tags, Random? random})
      : graph = graph ?? TasteGraph(),
        tags = tags ?? TagService(),
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
  // ремиксов, минусовок, speed up, DJ-сетов и того, что ты пропускаешь или скрыл. Известные теги
  // кандидата должны совпадать со стартовой песней; мягкий и запасной проходы это не отменяют.

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

  /// Почему трек не годится для радио (null — годится). [relaxed] — мягкий проход:
  /// исполнителей, которых ты часто пропускаешь, всё-таки можно.
  String? _reject(Track t, RadioSeed seed, RadioSession session, {bool relaxed = false}) {
    if (t.previewOnly || t.isVideo) return 'только фрагмент / видео';
    final artist = trueArtist(t);
    if (!library.allowedInRecs(t) || library.dislikedArtists.contains(Library.artistKey(artist))) {
      return 'скрыто («Не нравится»)';
    }
    if (session.blocked(artist)) return 'пропущен в этом радио';
    if (!relaxed && library.oftenSkipped(artist)) return 'часто пропускаешь исполнителя';
    final seedTitle = (seed.track?.title ?? '').toLowerCase();
    for (final m in _otherCut.allMatches(t.title)) {
      if (!seedTitle.contains(m[0]!.toLowerCase())) return 'ремикс / минус / speed up';
    }
    final d = t.duration;
    if (d != null && d > Duration.zero && (d < const Duration(seconds: 50) || d > const Duration(minutes: 9))) {
      return 'обрывок или DJ-сет';
    }
    // арабская, индийская, тайская музыка с чужим жанром на SoundCloud — если сам такое не слушаешь
    if (_farScript.hasMatch('${t.title} ${t.artist}') && !_farScript.hasMatch(seedTitle) && !_listensFarScript()) {
      return 'чужой язык';
    }
    return null;
  }

  static final _farScript = RegExp(r'[֐-ۿऀ-ॿ฀-๿]');
  bool? _farCache;
  bool _listensFarScript() =>
      _farCache ??= library.history.take(200).any((t) => _farScript.hasMatch('${t.title} ${t.artist}'));

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

  // ---------- теги: куда целится радио ----------


  /// Рассчитать цель радио: смесь тегов стартовой песни (исполнителя, тега) и твоего профиля вкуса.
  /// Так после эмо-рэпа у любителя металла пойдёт то, что ближе к обоим (trap metal, металкор
  /// с читкой), а не просто «ещё эмо-рэп».
  Future<void> _aim(RadioSeed seed, RadioSession s) async {
    if (s.target != null && !s.feedbackDirty) return;
    Tags like = const {}, avoid = const {};
    try {
      (like, avoid) = await tags.profile(library).timeout(const Duration(seconds: 20));
    } catch (_) {}
    Tags seedTags = const {};
    try {
      switch (seed.kind) {
        case RadioKind.track:
          final t = seed.track!;
          seedTags = await tags.trackTags(t, artist: trueArtist(t)).timeout(const Duration(seconds: 12));
          if (seedTags.isEmpty) {
            final twin = await _scTwin(t);
            if (twin != null) seedTags = tags.cachedTrackTags(twin, artist: trueArtist(twin));
          }
        case RadioKind.artist:
          seedTags = await tags.artistTags(seed.artist).timeout(const Duration(seconds: 12));
        case RadioKind.tag:
          seedTags = TagService.normalize({seed.artist: 1.0});
        case RadioKind.wave:
          break;
      }
    } catch (_) {}
    final hasLike = like.isNotEmpty;
    // то, что есть у самой песни, не штрафуем: ты сам её выбрал
    s.avoid = {
      for (final e in avoid.entries)
        if (!seedTags.containsKey(e.key)) e.key: e.value,
    };
    s.seedTags = seedTags;
    s.like = like;
    s.seedWeight = switch (seed.kind) {
      RadioKind.wave => 0,
      RadioKind.track => hasLike ? 0.5 : 1,
      RadioKind.artist => hasLike ? 0.75 : 1,
      RadioKind.tag => hasLike ? 0.7 : 1,
    };
    s.target = switch (seed.kind) {
      RadioKind.wave => like,
      RadioKind.track =>
        seedTags.isEmpty ? like : TagService.blend([(seedTags, 0.5), (like, hasLike ? 0.5 : 0)]),
      RadioKind.artist => TagService.blend([(seedTags, 0.75), (like, hasLike ? 0.25 : 0)]),
      RadioKind.tag => TagService.blend([(seedTags, 0.7), (like, hasLike ? 0.3 : 0)]),
    };
    // по каким тегам добирать кандидатов: сначала «мостики» (есть и у песни, и у тебя), потом точные теги
    final bridges = seedTags.keys.where(like.containsKey).toList()
      ..sort((a, b) => min(seedTags[b]!, like[b]!).compareTo(min(seedTags[a]!, like[a]!)));
    final order = seed.kind == RadioKind.tag
        ? [seed.artist]
        : [...bridges, ...TagService.top(seedTags, 4), ...TagService.top(like, 3)];
    // только точные теги: поиск по «alternative rock» или «rap» приносит что угодно (Tame Impala, Стрыкало)
    final seen = <String>{};
    s.sourceTags = [
      for (final t in order)
        if ((seed.kind == RadioKind.tag || !TagService.isBroad(t)) && seen.add(t)) t,
    ].take(4).toList();
    s.feedbackDirty = false;
  }

  /// Оценка кандидата: насколько его теги совпадают с целью радио, минус то, чего ты избегаешь.
  double _score(Track t, RadioSession s) {
    final noise = _rnd.nextDouble() * 0.08;
    final tt = tags.cachedTrackTags(t, artist: trueArtist(t));
    final from = s.origin[t.key] ?? 'seed';
    // похоже на песню: по тегам, а если их нет — по тому, откуда кандидат
    final bySource = from == 'seed' ? 0.55 : (from == 'drift' ? 0.4 : 0.15);
    final seedPart = s.seedTags.isNotEmpty && tt.isNotEmpty ? TagService.similarity(tt, s.seedTags) : bySource;
    // похоже на твой вкус
    final likePart = s.like.isEmpty ? seedPart : (tt.isEmpty ? 0.2 : TagService.similarity(tt, s.like));
    final avoid = tt.isEmpty ? 0.0 : TagService.similarity(tt, s.avoid);
    return s.seedWeight * seedPart + (1 - s.seedWeight) * likePart - 0.6 * avoid + noise;
  }

  bool _genreMismatch(Track t, RadioSession s) {
    if (s.seedTags.isEmpty) return false;
    final tt = tags.cachedTrackTags(t, artist: trueArtist(t));
    return tt.isNotEmpty && !TagService.sameStyle(s.seedTags, tt);
  }

  /// Песни похожих исполнителей: у Звука — сразу играбельные популярные треки, у Last.fm — подсказки.
  Future<List<Track>> _similarArtistsTracks(String artist, {String? zvukId, int artists = 5, int per = 2}) =>
      _safe(() async {
        final sim = await tags.similarArtists(artist, zvukArtistId: zvukId);
        final pick = (sim.take(15).toList()..shuffle(_rnd)).take(artists).toList();
        final parts = await Future.wait(pick.map((a) => _safe(() async {
              final z = tags.zvuk;
              if (a.$2 != null && z != null) {
                final info = await z.artist(a.$2!);
                return (info?.topTracks ?? const <Track>[]).take(10).toList();
              }
              return tags.artistTopTracks(a.$1, limit: 10);
            })));
        return [for (final p in parts) ...(List.of(p)..shuffle(_rnd)).take(per)];
      });

  /// Песни по тегу: популярное с тегом на Last.fm и поиск по тегу на SoundCloud.
  Future<List<Track>> _tagTracks(String tag, {int page = 1}) async {
    final sc = search.sources.whereType<SoundCloudSource>().where((x) => x.isConfigured).firstOrNull;
    final r = await Future.wait([
      tags.hasLastfm ? _safe(() => tags.tagTopTracks(tag, page: page)) : _none(),
      sc == null ? _none() : _safe(() => sc.byTag(tag, offset: (page - 1) * 50)),
    ]);
    return [...r[0], ...r[1]];
  }

  /// Пополнить запас кандидатов радио.
  Future<void> _refill(RadioSeed seed, RadioSession session) async {
    final first = session.fills == 0;
    session.fills++;
    final parts = <(String, String, Future<List<Track>>)>[]; // (название источника, происхождение, треки)
    void add(String label, Future<List<Track>> f, {String? origin}) =>
        parts.add((label, origin ?? (first || seed.kind == RadioKind.tag ? 'seed' : 'drift'), f));
    void addTag(String tag, {int page = 1}) => add('по тегу #$tag', _tagTracks(tag, page: page), origin: 'tag');
    void addRotatingTag() {
      if (session.sourceTags.isEmpty) return;
      final i = session.fills % session.sourceTags.length;
      addTag(session.sourceTags[i], page: 1 + session.fills ~/ session.sourceTags.length);
    }

    switch (seed.kind) {
      case RadioKind.track:
        final seedTrack = seed.track!;
        if (first) {
          final a = await _graphArtist(trueArtist(seedTrack), title: seedTrack.title);
          add('станция SoundCloud', _station(seedTrack));
          if (a != null) {
            add('радио Deezer', _safe(() => graph.artistRadio(a.id)));
            add('похожие Deezer', _relatedTopsOf(a, artists: 4, perArtist: 2));
          }
          add('похожие исполнители (Звук/Last.fm)',
              _similarArtistsTracks(trueArtist(seedTrack),
                  zvukId: seedTrack.source == 'zvuk' ? seedTrack.artistId : null, artists: 6));
          // по жанрам здесь не ищем: только «кто слушает эту песню, слушает и…»
        } else {
          // дрейф: от того, что в этом радио дослушали
          add('станция дослушанного', _station(session.nextStationSeed(_rnd) ?? seedTrack));
          final liked = session.liked..shuffle(_rnd);
          add('радио Deezer', _graphRadio(liked.isNotEmpty ? liked.first : trueArtist(seedTrack)));
          add(liked.isNotEmpty ? 'похожие на дослушанных' : 'похожие исполнители (Звук/Last.fm)',
              _similarArtistsTracks(liked.isNotEmpty ? liked.first : trueArtist(seedTrack), artists: 5));
        }
      case RadioKind.artist:
        final a = await _graphArtist(seed.artist, title: seed.track?.title);
        if (a != null) {
          add('популярное Deezer', _safe(() => graph.artistTop(a.id, limit: 25)));
          add('радио Deezer', _safe(() => graph.artistRadio(a.id)));
        }
        add('станция SoundCloud', _station(first ? seed.track : session.nextStationSeed(_rnd) ?? seed.track));
        if (first) add('песни исполнителя', _artistTracks(seed.artist, sample: seed.track));
        add('похожие исполнители (Звук/Last.fm)',
            _similarArtistsTracks(seed.artist,
                zvukId: seed.track?.source == 'zvuk' ? seed.track!.artistId : null, artists: first ? 6 : 4));
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
          add('чарт Deezer', _safe(graph.chart), origin: 'tag'); // волна без истории — популярное
        } else {
          for (final b in bases) {
            add('радио Deezer: $b', _graphRadio(b));
          }
          // станция одной из песен любимых исполнителей (из истории или лайков)
          final keys = {for (final b in bases) Library.artistKey(b)};
          final mine = [...library.history, ...library.liked.tracks]
              .where((t) => !t.isPick && keys.contains(Library.artistKey(trueArtist(t))))
              .toList();
          add('станция SoundCloud',
              _station(session.nextStationSeed(_rnd) ?? (mine.isEmpty ? null : mine[_rnd.nextInt(mine.length)])));
          add('похожие на ${bases.first}', _similarArtistsTracks(bases.first, artists: 4));
          addRotatingTag();
        }
      case RadioKind.tag:
        add('по тегу #${seed.artist}', _tagTracks(seed.artist, page: session.fills));
        final liked = session.liked..shuffle(_rnd);
        if (liked.isNotEmpty) add('похожие на дослушанных', _similarArtistsTracks(liked.first, artists: 4));
        add('станция дослушанного', _station(session.nextStationSeed(_rnd)));
        if (tags.hasLastfm && first) {
          add('исполнители тега (Last.fm)', _safe(() async {
            final artists = (await tags.tagTopArtists(seed.artist, limit: 40))..shuffle(_rnd);
            final tops = await Future.wait(artists.take(6).map((a) => _safe(() => tags.artistTopTracks(a, limit: 6))));
            return [for (final t in tops) ...t.take(2)];
          }));
        }
    }
    final results = await Future.wait([for (final p in parts) p.$3]);
    final lists = [for (final l in results) List.of(l)..shuffle(_rnd)];
    for (var j = 0; j < parts.length; j++) {
      session.report.sources[parts[j].$1] = (session.report.sources[parts[j].$1] ?? 0) + results[j].length;
    }
    // источники чередуем, чтобы ни один не забивал радио
    final maxLen = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (var j = 0; j < lists.length; j++) {
        final l = lists[j];
        if (i < l.length && !_seen(session, l[i])) {
          session.pool.add(l[i]);
          session.origin.putIfAbsent(l[i].key, () => parts[j].$2);
          session.labels.putIfAbsent(l[i].key, () => parts[j].$1);
        }
      }
    }
  }

  /// Следующая порция радио: готовые к воспроизведению треки (уже найденные на площадках).
  ///
  /// Сначала строгий отбор (оценка по тегам, без того, что ты часто пропускаешь). Если строгий
  /// отбор оставил мало — второй, мягкий проход: радио не должно «пересыхать» до двух треков.
  /// Скрытое через «Не нравится» не возвращается никогда.
  Future<List<Track>> radioBatch(RadioSeed seed, Set<String> exclude, {RadioSession? session, int want = 10}) async {
    session ??= RadioSession();
    if (seed.kind == RadioKind.track && seed.track == null) return [];
    if (seed.track != null) _markSeen(session, seed.track!);
    session.excluded.addAll(exclude);
    await _aim(seed, session);
    final rep = session.report;
    final seedArtist = seed.kind == RadioKind.wave || seed.kind == RadioKind.tag ? '' : Library.artistKey(seed.artist);
    final seedCompact = seedArtist.replaceAll(' ', '');
    // чей трек: перезаливы вида «ati_hell — LAZZY2WICE STAY SAFE» — тоже песни самого исполнителя
    String whose(Track t) {
      final a = Library.artistKey(trueArtist(t));
      if (seedCompact.length >= 3 && a != seedArtist &&
          Track.normalize(t.title).replaceAll(' ', '').contains(seedCompact)) {
        return seedArtist;
      }
      return a;
    }
    // сколько песен самого исполнителя в порции
    final ownMax = switch (seed.kind) {
      RadioKind.artist => (want / 2).ceil(),
      RadioKind.track => max(2, want ~/ 4),
      RadioKind.wave || RadioKind.tag => 2,
    };

    final out = <Track>[];
    final perArtist = <String, int>{};
    final soft = <Track>[]; // отсеяны мягкими фильтрами — пригодятся во втором проходе

    Future<void> take(List<Track> cand) async {
      for (var i = 0; i < cand.length && out.length < want; i += 5) {
        final chunk = cand.skip(i).take(5).toList();
        final got = await Future.wait(chunk.map(resolve));
        for (var k = 0; k < got.length; k++) {
          final t = got[k];
          final src = chunk[k];
          if (t == null) {
            rep.count('не нашлось на площадках');
            continue;
          }
          if (out.length >= want || _reject(t, seed, session!, relaxed: true) != null) continue;
          if (session.excluded.contains(t.key)) continue;
          if (_markSeen(session, t)) {
            out.add(t);
            final tt = tags.cachedTrackTags(src, artist: trueArtist(src));
            rep.items.add('${trueArtist(t)} — ${t.title}'
                ' | ${session.labels[src.key] ?? '?'}'
                ' | ${tt.isEmpty ? 'тегов нет' : TagService.top(tt, 4).join(', ')}'
                ' | оценка ${_score(src, session).toStringAsFixed(2)}');
          }
        }
      }
    }

    for (var round = 0; round < 3 && out.length < want; round++) {
      if (session.pool.length < want * 2 && session.fills < 6) await _refill(seed, session);
      // теги кандидатов (известные берутся из памяти) и сортировка по оценке
      try {
        await tags
            .prefetch(session.pool.take(50).map(trueArtist), parallel: 8)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
      final scores = {for (final t in session.pool) t: _score(t, session)};
      session.pool.sort((a, b) => scores[b]!.compareTo(scores[a]!));
      final strictScore = session.seedTags.isNotEmpty || session.like.isNotEmpty;

      final origin = session.origin;
      var tagTaken = out.where((t) => origin[t.key] == 'tag').length;
      final cand = <Track>[];
      final keep = <Track>[];
      for (final t in session.pool) {
        if (cand.length >= (want - out.length) * 2) {
          keep.add(t);
          continue;
        }
        if (_seen(session, t) || session.excluded.contains(t.key) || session.excluded.contains(t.matchKey)) {
          rep.count('уже было / перезалив');
          continue;
        }
        final why = _reject(t, seed, session);
        if (why != null) {
          rep.count(why);
          if (why == 'часто пропускаешь исполнителя') soft.add(t);
          continue;
        }
        if (_genreMismatch(t, session)) {
          rep.count('другой жанр');
          continue;
        }
        if (strictScore && scores[t]! < 0.08) {
          rep.count('не подошло по тегам');
          soft.add(t);
          continue;
        }
        final a = whose(t);
        final limit = a == seedArtist ? ownMax : 2;
        // найденное по тегам — не больше 2/3 порции: радио должно оставаться про эту песню
        final fromTag = seed.kind != RadioKind.wave && seed.kind != RadioKind.tag && origin[t.key] == 'tag';
        if ((perArtist[a] ?? 0) >= limit || fromTag && tagTaken >= (want * 2 / 3).ceil()) {
          keep.add(t); // пригодится в следующих порциях
          continue;
        }
        perArtist[a] = (perArtist[a] ?? 0) + 1;
        if (fromTag) tagTaken++;
        cand.add(t);
      }
      session.pool
        ..clear()
        ..addAll(keep);
      await take(cand);
      if (cand.isEmpty && session.fills >= 6) break;
    }

    // мягкий проход: слабая оценка и «часто пропускаешь», но не заведомо другой жанр
    if (out.length < want) {
      rep.count('включён мягкий отбор');
      final rest = [...soft, ...session.pool]
          .where((t) => !_seen(session!, t) && !session.excluded.contains(t.key) && _reject(t, seed, session, relaxed: true) == null)
          .toList();
      final per = <String, int>{};
      final cand = <Track>[];
      for (final t in rest) {
        final a = whose(t);
        if ((per[a] ?? 0) + (perArtist[a] ?? 0) >= (a == seedArtist ? ownMax : 3)) continue;
        per[a] = (per[a] ?? 0) + 1;
        cand.add(t);
        if (cand.length >= (want - out.length) * 2) break;
      }
      session.pool.removeWhere(cand.contains);
      await take(cand);
    }

    if (out.length < want ~/ 2) {
      // ни станции, ни графа (нет сети, совсем нишевая песня) — запасной путь
      final fb = await _fallbackBatch(seed);
      rep.sources['запасной путь'] = (rep.sources['запасной путь'] ?? 0) + fb.length;
      for (final t in fb) {
        if (out.length >= want) break;
        if (_reject(t, seed, session, relaxed: true) == null &&
            !_genreMismatch(t, session) &&
            !session.excluded.contains(t.key) &&
            _markSeen(session, t)) {
          out.add(t);
        }
      }
    }
    rep.given += out.length;
    rep.lastTarget = TagService.top(session.seedTags, 5);
    rep.lastLike = TagService.top(session.like, 5);
    rep.lastAvoid = TagService.top(session.avoid, 5);
    rep.sourceTags = session.sourceTags;
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
