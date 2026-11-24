import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../sources/net.dart';
import '../sources/soundcloud.dart';
import '../sources/zvuk.dart';
import 'lyrics.dart';
import 'library.dart';

/// Теги (жанры и стили) с весами: {'metalcore': 1.0, 'metal': 0.6, ...}.
typedef Tags = Map<String, double>;

/// Теги песен и исполнителей и профиль вкуса по тегам.
///
/// Так подбирают музыку Last.fm и Pandora: у каждой песни есть набор тегов (жанров, стилей),
/// у слушателя — свой набор, собранный из того, что он слушает. Похожесть — насколько совпадают наборы.
///
/// Откуда теги (по важности):
/// 1. твои собственные теги исполнителя (кнопка ✎ в плеере) — главнее всего;
/// 2. теги слушателей SoundCloud: жанры и теги всех загрузок исполнителя и песни
///    (там у андерграунда точные теги — necrotrap, horrorcore, deathcore);
/// 3. Last.fm (если вшит ключ LASTFM_KEY);
/// 4. жанры релизов Звука — крупные и часто неточные, поэтому с малым весом.
class TagService {
  static const _builtInKey = String.fromEnvironment('LASTFM_KEY');
  static const _api = 'https://ws.audioscrobbler.com/2.0/';
  // v2: теги пересчитываются (в v1 были только крупные жанры Звука)
  static const _prefKey = 'artist_tags_v2';

  final String key;

  /// Звук: жанры релизов и похожие исполнители.
  final ZvukSource? zvuk;

  /// SoundCloud: теги слушателей.
  final SoundCloudSource? sc;

  /// Свои теги исполнителя (artistKey → теги), если человек их задал.
  List<String>? Function(String artistKey)? userTags;

  TagService({String? key, this.zvuk, this.sc}) : key = key ?? _builtInKey;

  bool get hasZvuk => zvuk?.isConfigured == true;
  bool get hasSc => sc?.isConfigured == true;

  bool get hasLastfm => key.isNotEmpty;

  // ---------- нормализация ----------

  /// Мусорные теги Last.fm: ничего не говорят о звучании.
  static final _junk = RegExp(
      r'^(seen live|favou?rites?|my favou?rites?|love|loved|awesome|beautiful|cool|good|best|amazing|albums i own|'
      r'under \d+ listeners|male vocalists?|female vocalists?|spotify|soundcloud|youtube|free download|new|music|'
      r'other|misc|none|unknown|all|\d{4}s?|\d0s|tracks?|songs?|singles?|instrumental|beats?|туса|music video|'
      r'check out|to listen|listen|vk|deezer|apple music|trash|shit|meme)$');

  static const _synonyms = {
    'hip hop': 'hip-hop',
    'hiphop': 'hip-hop',
    'hip-hop & rap': 'hip-hop',
    'hip-hop and rap': 'hip-hop',
    'rap/hip hop': 'hip-hop',
    'rap & hip-hop': 'hip-hop',
    'рэп': 'rap',
    'реп': 'rap',
    'хип-хоп': 'hip-hop',
    'русский рэп': 'russian rap',
    'русский рок': 'russian rock',
    'рок': 'rock',
    'метал': 'metal',
    'металл': 'metal',
    'панк': 'punk',
    'фонк': 'phonk',
    'heavy': 'heavy metal',
    'nu-metal': 'nu metal',
    'numetal': 'nu metal',
    'post hardcore': 'post-hardcore',
    'posthardcore': 'post-hardcore',
    'trapmetal': 'trap metal',
    'emorap': 'emo rap',
    'emo-rap': 'emo rap',
    'cloudrap': 'cloud rap',
    'electronica': 'electronic',
    'edm': 'electronic',
    'dance & edm': 'electronic',
    'drum & bass': 'drum and bass',
    'dnb': 'drum and bass',
    'd&b': 'drum and bass',
    'r&b & soul': 'rnb',
    'r&b': 'rnb',
    'rnb/soul': 'rnb',
    'k pop': 'k-pop',
    'kpop': 'k-pop',
    'alternative': 'alternative rock',
    // жанры Звука
    'русский хип-хоп': 'russian rap',
    'хип-хоп и рэп': 'hip-hop',
    'рэп и хип-хоп': 'hip-hop',
    'поп': 'pop',
    'русская поп-музыка': 'russian pop',
    'русский поп': 'russian pop',
    'альтернатива': 'alternative',
    'альтернативный рок': 'alternative rock',
    'инди': 'indie',
    'электроника': 'electronic',
    'электронная': 'electronic',
    'танцевальная': 'dance',
    'хардкор': 'hardcore',
    'металкор': 'metalcore',
    'дэткор': 'deathcore',
    'ню-метал': 'nu metal',
    'хэви-метал': 'heavy metal',
    'тяжёлый рок': 'hard rock',
    'тяжелый рок': 'hard rock',
    'трэп': 'trap',
    'дрилл': 'drill',
    'эмо': 'emo',
    'панк-рок': 'punk rock',
    'пост-панк': 'post-punk',
    'шансон': 'chanson',
    'джаз': 'jazz',
    'блюз': 'blues',
    'классика': 'classical',
    'классическая музыка': 'classical',
    'саундтреки': 'soundtrack',
  };

  static const _metalChildren = [
    'deathcore', 'metalcore', 'grindcore', 'mathcore', 'djent', 'sludge', 'doom', 'thrash', 'black metal',
    'death metal', 'nu metal', 'heavy metal', 'industrial metal', 'trap metal', 'groove metal', 'speed metal',
    'power metal', 'progressive metal', 'post-metal', 'goregrind', 'slam', 'beatdown', 'brutal death metal',
  ];

  /// Родительские жанры: «deathcore» значит ещё и «metal», «emo rap» — ещё и «hip-hop».
  static List<String> _parents(String tag) {
    final out = <String>[];
    if (tag != 'metal' && (tag.contains('metal') || _metalChildren.contains(tag))) out.add('metal');
    if (tag.endsWith('rap') && tag != 'rap' || tag == 'trap' || tag == 'drill' || tag == 'phonk' || tag == 'grime') {
      out.add('hip-hop');
    }
    if (tag == 'rap') out.add('hip-hop');
    if (tag == 'trap metal') out.addAll(['trap', 'hip-hop']);
    if (tag == 'post-hardcore' || tag == 'hardcore' || tag == 'hardcore punk' || tag.endsWith('punk') && tag != 'punk') {
      out.add('punk');
    }
    if (tag.endsWith(' rock') && tag != 'russian rock' || tag == 'emo' || tag == 'grunge' || tag == 'shoegaze') {
      out.add('rock');
    }
    if (tag == 'russian rock') out.addAll(['rock', 'russian']);
    if (tag == 'russian rap') out.addAll(['hip-hop', 'russian']);
    if (tag == 'hyperpop' || tag == 'digicore' || tag == 'glitchcore') out.add('electronic');
    if (tag == 'necrotrap' || tag == 'horrorcore' || tag == 'horror trap' || tag == 'rage' || tag == 'memphis rap') {
      out.addAll(['trap', 'hip-hop']);
    }
    if (tag == 'horrorclub' || tag == 'jerseyclub' || tag == 'jersey club') out.add('club');
    return out;
  }

  /// Привести теги к одному словарю: регистр, синонимы, мусор, родительские жанры. Вес — 0..1.
  static Tags normalize(Map<String, double> raw) {
    final out = <String, double>{};
    void put(String t, double w) => out[t] = max(out[t] ?? 0, w);
    // «Metal/Hard Rock», «Dance & EDM» — несколько жанров в одном (но не синонимы вроде «hip-hop & rap»)
    final split = <String, double>{};
    raw.forEach((k, v) {
      final low = k.toLowerCase().trim();
      if (_synonyms.containsKey(low) || !RegExp(r'[/,]| & ').hasMatch(low)) {
        split[k] = max(split[k] ?? 0, v);
      } else {
        for (final part in low.split(RegExp(r'\s*(?:/|,| & )\s*'))) {
          if (part.isNotEmpty) split[part] = max(split[part] ?? 0, v);
        }
      }
    });
    for (final e in split.entries) {
      var t = e.key.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ').replaceAll('_', ' ');
      if (t.isEmpty || t.length > 30) continue;
      t = _synonyms[t] ?? t;
      if (_junk.hasMatch(t)) continue;
      final w = e.value.clamp(0.0, 1.0).toDouble();
      if (w <= 0) continue;
      // «russian» и другие языки — слабый признак, а не жанр
      put(t, t == 'russian' || t == 'english' || t == 'korean' ? w * 0.4 : w);
      for (final p in _parents(t)) {
        put(p, w * 0.6);
      }
    }
    return out;
  }

  static double _norm(Tags a) => sqrt(a.values.fold<double>(0, (s, v) => s + v * v));

  /// Общие жанры: они есть у тысяч непохожих исполнителей (у LAZZY2WICE и у Tame Impala
  /// одинаково «alternative rock»), поэтому почти ничего не говорят о похожести.
  static const _broadTags = {
    'russian', 'english', 'korean', 'pop', 'rock', 'alternative rock', 'alternative', 'indie', 'indie rock',
    'hip-hop', 'rap', 'russian rap', 'trap', 'rnb', 'electronic', 'dance', 'hard rock', 'metal', 'punk', 'soul',
    'russian pop', 'russian rock', 'singer-songwriter', 'acoustic', 'soundtrack',
  };

  static bool isBroad(String tag) => _broadTags.contains(tag);

  /// Вес тега в сравнении: точные (deathcore, trap metal, emo rap) — полный, общие — малый.
  static double _idf(String tag) => _broadTags.contains(tag) ? 0.3 : 1.0;

  /// Косинусная похожесть наборов тегов (общие жанры весят мало): 0 — ничего общего, 1 — одно и то же.
  static double similarity(Tags a, Tags b) {
    if (a.isEmpty || b.isEmpty) return 0;
    // совпадение по общему жанру засчитывается с малым весом, а длины наборов — полные:
    // два исполнителя, у которых общего только «rock», почти непохожи
    var dot = 0.0;
    for (final e in a.entries) {
      final w = b[e.key];
      if (w != null) dot += e.value * w * _idf(e.key) * _idf(e.key);
    }
    final n = _norm(a) * _norm(b);
    return n == 0 ? 0 : dot / n;
  }

  static Set<String> _leafTags(Tags t) {
    final keys = t.keys.toSet();
    return {
      for (final tag in keys)
        if (!isBroad(tag) && !keys.any((other) => other != tag && _parents(other).contains(tag))) tag,
    };
  }

  /// Совместимы ли стили. Общий родитель не заменяет конкретный поджанр стартовой песни,
  /// но для широкого стартового жанра и для двух конкретных потомков одного жанра это допустимо.
  static bool sameStyle(Tags seed, Tags candidate) {
    if (seed.isEmpty || candidate.isEmpty || similarity(seed, candidate) >= 0.08) return true;
    final a = _leafTags(seed);
    if (a.isEmpty) return true;
    final b = _leafTags(candidate);
    if (b.isEmpty) return false;
    for (final x in a) {
      final parents = _parents(x).toSet();
      for (final y in b) {
        if (x == y || parents.any(_parents(y).contains)) return true;
      }
    }
    return false;
  }

  /// Смесь наборов с весами (каждый сначала приводится к длине 1).
  static Tags blend(List<(Tags, double)> parts) {
    final out = <String, double>{};
    for (final (t, w) in parts) {
      final n = _norm(t);
      if (n == 0 || w == 0) continue;
      t.forEach((k, v) => out[k] = (out[k] ?? 0) + v / n * w);
    }
    return out;
  }

  /// Самые весомые теги.
  static List<String> top(Tags t, [int n = 5]) {
    final keys = t.keys.toList()..sort((a, b) => t[b]!.compareTo(t[a]!));
    return keys.take(n).toList();
  }

  // ---------- Last.fm ----------

  Future<Map?> _lastfm(String method, Map<String, String> params) async {
    if (!hasLastfm) return null;
    final uri = Uri.parse(_api).replace(queryParameters: {
      'method': method,
      'api_key': key,
      'format': 'json',
      'autocorrect': '1',
      ...params,
    });
    final r = await Net.client.get(uri).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return j is Map && j['error'] == null ? j : null;
  }

  static Tags _fromLastfm(Map? j, String root) {
    final list = ((j?[root] as Map?)?['tag'] as List?) ?? const [];
    final raw = <String, double>{};
    for (final t in list.take(15)) {
      final c = t['count'];
      final w = (c is num ? c.toDouble() : double.tryParse('$c') ?? 0) / 100;
      if (t['name'] is String && w >= 0.05) raw[t['name']] = w;
    }
    return normalize(raw);
  }

  // ---------- кэш тегов исполнителей ----------

  final Map<String, Tags> _artists = {};
  bool _loaded = false;
  Timer? _saveTimer;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map;
      j.forEach((k, v) {
        _artists['$k'] = {for (final e in (v as Map).entries) '${e.key}': (e.value as num).toDouble()};
      });
    } catch (_) {}
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () async {
      // держим не больше 3000 исполнителей
      while (_artists.length > 3000) {
        _artists.remove(_artists.keys.first);
      }
      try {
        (await SharedPreferences.getInstance()).setString(_prefKey, jsonEncode(_artists));
      } catch (_) {}
    });
  }

  final Map<String, Future<Tags>> _inflight = {};

  static String _compact(String s) => Track.normalize(s).replaceAll(' ', '');

  /// Свои теги исполнителя, если человек их задал.
  Tags? _user(String artistKey) {
    final u = userTags?.call(artistKey);
    if (u == null || u.isEmpty) return null;
    return normalize({for (final t in u) t: 1.0});
  }

  /// Теги слушателей SoundCloud: жанры и теги всех загрузок исполнителя (и песни, если задана).
  /// Чем у большего числа загрузок тег, тем больше вес. Имена и ники как теги не берём.
  Future<Tags> _fromSoundCloud(String name, {String? title}) async {
    if (!hasSc) return const {};
    final queries = [name, if (title != null && title.trim().isNotEmpty) '$name ${LyricsService.cleanTitle(title)}'];
    final lists = await Future.wait(queries.map((q) async {
      try {
        return await sc!.search(q).timeout(const Duration(seconds: 8));
      } catch (_) {
        return const <Track>[];
      }
    }));
    final want = _compact(name);
    final raw = name.toLowerCase().trim();
    final seen = <String>{};
    final count = <String, double>{};
    var mine = 0;
    for (final t in lists.expand((x) => x)) {
      if (!seen.add(t.key)) continue;
      final dash = RegExp(r'\s[-–—]\s').firstMatch(t.title);
      final titleArtist = dash != null && dash.start > 0 ? _compact(t.title.substring(0, dash.start)) : '';
      final low = t.title.toLowerCase();
      // загрузка этого исполнителя: его аккаунт, «Исполнитель - Песня» или имя в названии (если имя не короткое)
      final isMine = _compact(t.artist) == want ||
          titleArtist == want ||
          raw.length >= 4 && low.contains(raw) ||
          want.length >= 5 && _compact(t.title).contains(want);
      if (!isMine) continue;
      mine++;
      final here = <String>{
        if (t.genre != null) t.genre!,
        for (final x in (t.extra['tags'] as List? ?? const [])) '$x',
      };
      for (var g in here) {
        g = g.replaceAll('#', '').trim();
        final c = _compact(g);
        // имя самого исполнителя, ники, ссылки и мусор — не теги
        if (c.length < 3 || c == want || g.contains('@') || g.contains('http') || RegExp(r'[$€£]').hasMatch(g)) {
          continue;
        }
        count[g.toLowerCase()] = (count[g.toLowerCase()] ?? 0) + 1;
      }
    }
    if (mine == 0 || count.isEmpty) return const {};
    // у кого много загрузок — тег должен встречаться хотя бы дважды (иначе это чья-то случайная пометка)
    final minCount = mine >= 6 ? 2 : 1;
    final most = count.values.fold<double>(0, max);
    return normalize({
      for (final e in count.entries)
        if (e.value >= minCount) e.key: e.value / most,
    });
  }

  /// Теги исполнителя. Свои — главнее всего; иначе SoundCloud + Last.fm + (с малым весом) Звук.
  /// Запоминаются на устройстве.
  Future<Tags> artistTags(String artist, {String? zvukArtistId, String? title}) async {
    await _load();
    final k = Library.artistKey(artist);
    if (k.isEmpty) return const {};
    final own = _user(k);
    if (own != null) return own;
    final hit = _artists[k];
    if (hit != null) return hit;
    if (!hasLastfm && !hasZvuk && !hasSc) return const {};
    return _inflight[k] ??= () async {
      try {
        final name = artist.split(RegExp(r',|&| feat\.? | ft\.? | x ', caseSensitive: false)).first.trim();
        var failed = 0;
        Future<Tags> fromZvuk() async {
          if (!hasZvuk) return const {};
          try {
            final id = zvukArtistId ?? await zvuk!.findArtistId(name);
            if (id == null) return const {};
            return normalize(await zvuk!.artistGenres(id));
          } catch (_) {
            failed++;
            return const {};
          }
        }

        Future<Tags> fromLastfm() async {
          if (!hasLastfm) return const {};
          try {
            return _fromLastfm(await _lastfm('artist.gettoptags', {'artist': name}), 'toptags');
          } catch (_) {
            failed++;
            return const {};
          }
        }

        final r = await Future.wait([_fromSoundCloud(name, title: title), fromLastfm(), fromZvuk()]);
        final crowd = r[0].isNotEmpty || r[1].isNotEmpty;
        // теги слушателей главнее; жанры Звука крупные и часто мимо — только подсказка
        final tags = blend([
          (r[0], r[0].isEmpty ? 0 : 1.0),
          (r[1], r[1].isEmpty ? 0 : 1.0),
          (r[2], r[2].isEmpty ? 0 : (crowd ? 0.2 : 0.6)),
        ]);
        // пустой набор тоже запоминаем (значит, тегов нет), но не после сбоя сети
        if (tags.isNotEmpty || failed == 0) {
          _artists[k] = tags;
          _save();
        }
        return tags;
      } finally {
        unawaited(Future(() => _inflight.remove(k)));
      }
    }();
  }

  /// Забыть запомненные автоматические теги исполнителя (пересчитать заново).
  void forget(String artist) => _artists.remove(Library.artistKey(artist));

  final Map<String, List<String>> _releases = {};

  /// Теги трека: свои теги исполнителя, иначе теги площадки + теги исполнителя
  /// (жанры релиза Звука — с малым весом).
  Future<Tags> trackTags(Track t, {String? artist}) async {
    final a0 = artist ?? t.artist;
    final own = _user(Library.artistKey(a0));
    if (own != null) return own;
    final mine = <String, double>{
      if (t.genre != null && t.genre!.trim().isNotEmpty) t.genre!: 1.0,
      for (final x in (t.extra['tags'] as List? ?? const [])) '$x': 0.6,
    };
    Tags zvukRelease = const {};
    if (t.source == 'zvuk' && t.albumId != null && hasZvuk) {
      try {
        final g = _releases[t.albumId!] ??= await zvuk!.releaseGenres(t.albumId!);
        zvukRelease = normalize({for (final x in g) x: 1.0});
      } catch (_) {}
    }
    final a = await artistTags(a0, zvukArtistId: t.source == 'zvuk' ? t.artistId : null, title: t.title);
    return blend([
      (normalize(mine), mine.isEmpty ? 0 : 0.5),
      (a, a.isEmpty ? 0 : 1.0),
      (zvukRelease, zvukRelease.isEmpty ? 0 : 0.15),
    ]);
  }

  /// Теги, которые уже известны без сети (для быстрой сортировки большого списка).
  Tags cachedTrackTags(Track t, {String? artist}) {
    final k = Library.artistKey(artist ?? t.artist);
    final own = _user(k);
    if (own != null) return own;
    final mine = <String, double>{
      if (t.genre != null && t.genre!.trim().isNotEmpty) t.genre!: 1.0,
      for (final x in (t.extra['tags'] as List? ?? const [])) '$x': 0.6,
    };
    final a = _artists[k] ?? const {};
    return blend([(normalize(mine), mine.isEmpty ? 0 : 0.5), (a, a.isEmpty ? 0 : 1.0)]);
  }

  /// Подготовить теги многих исполнителей сразу (по [parallel] запросов).
  Future<void> prefetch(Iterable<String> artists, {int parallel = 8}) async {
    await _load();
    final todo = {
      for (final a in artists)
        if (Library.artistKey(a).isNotEmpty && !_artists.containsKey(Library.artistKey(a))) Library.artistKey(a): a,
    }.values.toList();
    for (var i = 0; i < todo.length; i += parallel) {
      await Future.wait(todo.skip(i).take(parallel).map(artistTags));
    }
  }

  // ---------- профиль вкуса ----------

  (Tags, Tags)? _profile;
  DateTime? _profileAt;

  /// Профиль вкуса: (что любишь, чего избегаешь) — теги любимых исполнителей с их весами
  /// и теги тех, кого пропускаешь или скрыл.
  Future<(Tags, Tags)> profile(Library library, {bool force = false}) async {
    if (!force && _profile != null && DateTime.now().difference(_profileAt!) < const Duration(minutes: 5)) {
      return _profile!;
    }
    final scores = library.artistScores().values.toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final good = scores.where((s) => s.$2 > 0).take(25).toList();
    final bad = scores.reversed.where((s) => s.$2 < 0).take(10).toList();
    await prefetch([for (final s in [...good, ...bad]) s.$1]);
    final like = blend([for (final s in good) (_artists[Library.artistKey(s.$1)] ?? const {}, s.$2)]);
    final avoid = blend([for (final s in bad) (_artists[Library.artistKey(s.$1)] ?? const {}, -s.$2)]);
    // свои файлы и треки с жанром тоже подсказывают вкус
    final genres = <String, double>{};
    for (final t in [...library.liked.tracks.take(100), ...library.history.take(100)]) {
      if (t.genre != null) genres[t.genre!] = (genres[t.genre!] ?? 0) + 0.2;
    }
    final g = normalize({for (final e in genres.entries) e.key: min(1.0, e.value)});
    _profile = (blend([(like, 1.0), (g, g.isEmpty ? 0 : 0.3)]), avoid);
    _profileAt = DateTime.now();
    return _profile!;
  }

  void invalidateProfile() => _profile = null;

  // ---------- источники кандидатов по тегам ----------

  static Track _hint(Map t, {String? artistName}) {
    final artist = artistName ?? (t['artist'] is Map ? t['artist']['name'] : t['artist']) ?? '';
    final images = (t['image'] as List?) ?? const [];
    String? cover;
    for (final i in images.reversed) {
      final u = i is Map ? i['#text'] as String? : null;
      // у Last.fm вместо обложки часто серая заглушка — её не берём
      if (u != null && u.isNotEmpty && !u.contains('2a96cbd8b46e442fc41c2b86b821562f')) {
        cover = u;
        break;
      }
    }
    final d = int.tryParse('${t['duration'] ?? ''}');
    return Track(
      source: Track.pickSource,
      id: 'lf:${'$artist|${t['name']}'.hashCode}',
      title: '${t['name'] ?? ''}',
      artist: '$artist',
      coverUrl: cover,
      // в tag.gettoptracks длина в секундах, в artist.gettoptracks её нет
      duration: d != null && d > 0 ? Duration(seconds: d) : null,
    );
  }

  /// Популярные песни с тегом (Last.fm).
  Future<List<Track>> tagTopTracks(String tag, {int limit = 50, int page = 1}) async {
    final j = await _lastfm('tag.gettoptracks', {'tag': tag, 'limit': '$limit', 'page': '$page'});
    final list = ((j?['tracks'] as Map?)?['track'] as List?) ?? const [];
    return [for (final t in list.whereType<Map>()) _hint(t)];
  }

  /// Исполнители с тегом (Last.fm).
  Future<List<String>> tagTopArtists(String tag, {int limit = 50}) async {
    final j = await _lastfm('tag.gettopartists', {'tag': tag, 'limit': '$limit'});
    final list = ((j?['topartists'] as Map?)?['artist'] as List?) ?? const [];
    return [for (final a in list.whereType<Map>()) '${a['name']}'];
  }

  /// Похожие исполнители: Звук (его «похожие») и Last.fm (по совместным прослушиваниям).
  /// Для Звука сразу отдаём id — его популярные треки можно играть без поиска.
  Future<List<(String, String?)>> similarArtists(String artist, {int limit = 30, String? zvukArtistId}) async {
    final name = artist.split(RegExp(r',|&| feat\.? | ft\.? | x ', caseSensitive: false)).first.trim();
    Future<List<(String, String?)>> z() async {
      if (!hasZvuk) return const [];
      try {
        final id = zvukArtistId ?? await zvuk!.findArtistId(name);
        if (id == null) return const [];
        return [for (final a in await zvuk!.relatedArtists(id, limit: limit)) (a.name, a.id)];
      } catch (_) {
        return const [];
      }
    }

    Future<List<(String, String?)>> l() async {
      try {
        final j = await _lastfm('artist.getsimilar', {'artist': name, 'limit': '$limit'});
        final list = ((j?['similarartists'] as Map?)?['artist'] as List?) ?? const [];
        return [for (final a in list.whereType<Map>()) ('${a['name']}', null)];
      } catch (_) {
        return const [];
      }
    }

    final r = await Future.wait([z(), l()]);
    final seen = <String>{};
    final out = <(String, String?)>[];
    // чередуем: оба источника одинаково важны
    for (var i = 0; i < max(r[0].length, r[1].length); i++) {
      for (final list in r) {
        if (i < list.length && seen.add(Library.artistKey(list[i].$1))) out.add(list[i]);
      }
    }
    return out;
  }

  /// Популярные песни исполнителя (Last.fm).
  Future<List<Track>> artistTopTracks(String artist, {int limit = 10}) async {
    final j = await _lastfm('artist.gettoptracks', {'artist': artist, 'limit': '$limit'});
    final list = ((j?['toptracks'] as Map?)?['track'] as List?) ?? const [];
    return [for (final t in list.whereType<Map>()) _hint(t, artistName: artist)];
  }
}
