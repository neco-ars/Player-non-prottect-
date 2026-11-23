import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../sources/net.dart';
import '../sources/zvuk.dart';
import 'library.dart';

/// Теги (жанры и стили) с весами: {'metalcore': 1.0, 'metal': 0.6, ...}.
typedef Tags = Map<String, double>;

/// Теги песен и исполнителей и профиль вкуса по тегам.
///
/// Так подбирают музыку Last.fm и Pandora: у каждой песни есть набор тегов (жанров, стилей),
/// у слушателя — свой набор, собранный из того, что он слушает. Похожесть — насколько совпадают наборы.
///
/// Откуда теги: Last.fm (теги, которые ставят слушатели, — лучшие, нужен бесплатный ключ LASTFM_KEY),
/// жанр и теги трека с SoundCloud/Audiomack, жанр из тегов своих файлов.
class TagService {
  static const _builtInKey = String.fromEnvironment('LASTFM_KEY');
  static const _api = 'https://ws.audioscrobbler.com/2.0/';
  static const _prefKey = 'artist_tags_v1';

  final String key;

  /// Звук: жанры релизов и похожие исполнители — главный источник для русской музыки.
  final ZvukSource? zvuk;
  TagService({String? key, this.zvuk}) : key = key ?? _builtInKey;

  bool get hasZvuk => zvuk?.isConfigured == true;

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

  /// Косинусная похожесть наборов тегов: 0 — ничего общего, 1 — одно и то же.
  static double similarity(Tags a, Tags b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var dot = 0.0;
    for (final e in a.entries) {
      final w = b[e.key];
      if (w != null) dot += e.value * w;
    }
    final n = _norm(a) * _norm(b);
    return n == 0 ? 0 : dot / n;
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

  /// Теги исполнителя (Last.fm). Запоминаются на устройстве.
  Future<Tags> artistTags(String artist, {String? zvukArtistId}) async {
    await _load();
    final k = Library.artistKey(artist);
    if (k.isEmpty) return const {};
    final hit = _artists[k];
    if (hit != null) return hit;
    if (!hasLastfm && !hasZvuk) return const {};
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

        final r = await Future.wait([fromZvuk(), fromLastfm()]);
        // жанры Звука крупные (рэп, метал), теги Last.fm подробные (emo rap, deathcore) — берём оба
        final tags = blend([(r[0], r[0].isEmpty ? 0 : 0.8), (r[1], r[1].isEmpty ? 0 : 1.0)]);
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

  final Map<String, List<String>> _releases = {};

  /// Теги трека: жанр и теги площадки (у Звука — жанры релиза) + теги исполнителя.
  Future<Tags> trackTags(Track t, {String? artist}) async {
    final own = <String, double>{
      if (t.genre != null && t.genre!.trim().isNotEmpty) t.genre!: 1.0,
      for (final x in (t.extra['tags'] as List? ?? const [])) '$x': 0.6,
    };
    if (t.source == 'zvuk' && t.albumId != null && hasZvuk) {
      try {
        final g = _releases[t.albumId!] ??= await zvuk!.releaseGenres(t.albumId!);
        for (final x in g) {
          own[x] = 1.0;
        }
      } catch (_) {}
    }
    final a = await artistTags(artist ?? t.artist, zvukArtistId: t.source == 'zvuk' ? t.artistId : null);
    return blend([(normalize(own), own.isEmpty ? 0 : 0.5), (a, a.isEmpty ? 0 : 1.0)]);
  }

  /// Теги, которые уже известны без сети (для быстрой сортировки большого списка).
  Tags cachedTrackTags(Track t, {String? artist}) {
    final own = <String, double>{
      if (t.genre != null && t.genre!.trim().isNotEmpty) t.genre!: 1.0,
      for (final x in (t.extra['tags'] as List? ?? const [])) '$x': 0.6,
    };
    final a = _artists[Library.artistKey(artist ?? t.artist)] ?? const {};
    return blend([(normalize(own), own.isEmpty ? 0 : 0.5), (a, a.isEmpty ? 0 : 1.0)]);
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
