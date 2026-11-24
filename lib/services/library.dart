import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';

/// Где лежит library.json: файл на устройстве или хранилище браузера.
abstract class _Store {
  Future<String?> read();
  Future<void> write(String data);
  Future<void> backup(String data);
}

class _FileStore implements _Store {
  final File file;
  _FileStore(this.file);
  @override
  Future<String?> read() async => await file.exists() ? file.readAsString() : null;
  @override
  Future<void> write(String data) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> backup(String data) async {
    try {
      await File('${file.path}.broken-${DateTime.now().millisecondsSinceEpoch}').writeAsString(data);
    } catch (_) {}
  }
}

class _WebStore implements _Store {
  static const _key = 'library_json';
  @override
  Future<String?> read() async => (await SharedPreferences.getInstance()).getString(_key);
  @override
  Future<void> write(String data) async => (await SharedPreferences.getInstance()).setString(_key, data);

  @override
  Future<void> backup(String data) async => (await SharedPreferences.getInstance()).setString('${_key}_broken', data);
}

/// В памяти — для тестов.
class _MemStore implements _Store {
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String d) async => data = d;
  @override
  Future<void> backup(String d) async {}
}

class Playlist {
  final String id;
  String name;
  final List<Track> tracks;
  Playlist({required this.id, required this.name, List<Track>? tracks}) : tracks = tracks ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'tracks': tracks.map((t) => t.toJson()).toList()};
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'],
        name: j['name'],
        tracks: (j['tracks'] as List).map((t) => Track.fromJson(Map<String, dynamic>.from(t))).toList(),
      );
}

/// Плейлисты, «Любимое» и история. Хранится в одном JSON-файле на устройстве.
class Library extends ChangeNotifier {
  static const likedId = 'liked';
  static const historyLimit = 300;

  final _Store _store;
  final List<Playlist> playlists = [];
  final List<Track> history = []; // самые свежие в начале
  Timer? _saveTimer;

  // ---------- для синхронизации между устройствами ----------
  /// Когда менялась каждая часть библиотеки (мс): 'pl:<id>' — плейлист, 'disliked' — «Скрытое».
  /// При слиянии с облаком побеждает более свежая версия части.
  final Map<String, int> stamps = {};

  /// Удалённые плейлисты: id → когда удалили. Чтобы облако не вернуло их обратно.
  final Map<String, int> deletedPlaylists = {};

  /// Когда трек из истории слушали последний раз (ключ — track.key).
  final Map<String, int> historyAt = {};

  /// Вызывается после каждого сохранения (синхронизация отправляет изменения в облако).
  void Function()? onSaved;

  static int get _now => DateTime.now().millisecondsSinceEpoch;
  void _touch(String part) => stamps[part] = _now;

  Library._(this._store);

  /// Пустая библиотека в памяти (для тестов).
  @visibleForTesting
  factory Library.memory() => Library._(_MemStore()).._ensureLiked();

  static Future<Library> load() async {
    final _Store store;
    if (kIsWeb) {
      store = _WebStore();
    } else {
      final dir = await getApplicationSupportDirectory();
      store = _FileStore(File('${dir.path}${Platform.pathSeparator}library.json'));
    }
    final lib = Library._(store);
    String? raw;
    try {
      raw = await store.read();
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        // битые записи пропускаем по одной, а не теряем из-за них всю библиотеку
        lib.playlists.addAll(_each(j['playlists'], (p) => Playlist.fromJson(Map<String, dynamic>.from(p))));
        lib.history.addAll(_each(j['history'], (t) => Track.fromJson(Map<String, dynamic>.from(t))));
        lib.disliked.addAll(_each(j['disliked'], (t) => Track.fromJson(Map<String, dynamic>.from(t))));
        lib._readMeta(j);
      }
    } catch (e) {
      debugPrint('library.json повреждён, начинаем заново: $e');
      // сохраняем испорченный файл рядом, чтобы его можно было восстановить вручную
      if (raw != null) await store.backup(raw);
    }
    lib._ensureLiked();
    // у истории из старых версий нет времени — сохраняем хотя бы порядок
    final base = _now;
    for (var i = 0; i < lib.history.length; i++) {
      lib.historyAt.putIfAbsent(lib.history[i].key, () => base - (i + 1) * 1000);
    }
    return lib;
  }

  void _ensureLiked() {
    if (!playlists.any((p) => p.id == likedId)) {
      playlists.insert(0, Playlist(id: likedId, name: 'Любимое'));
    }
  }

  static Map<String, int> _ints(dynamic m) => {
        for (final e in ((m is Map) ? m : const {}).entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
      };

  void _readMeta(Map<String, dynamic> j) {
    stamps.addAll(_ints(j['stamps']));
    deletedPlaylists.addAll(_ints(j['deleted']));
    historyAt.addAll(_ints(j['historyAt']));
    final ut = j['userTags'];
    if (ut is Map) {
      for (final e in ut.entries) {
        if (e.value is List) userTags['${e.key}'] = [for (final x in e.value as List) '$x'];
      }
    }
    final arts = j['artists'];
    if (arts is Map) {
      for (final e in arts.entries) {
        try {
          artists['${e.key}'] = ArtistStat.fromJson(Map<String, dynamic>.from(e.value));
        } catch (_) {}
      }
    }
  }

  /// Разобрать список, пропуская элементы, которые не читаются.
  static List<T> _each<T>(dynamic list, T Function(dynamic) parse) {
    final out = <T>[];
    for (final x in (list as List?) ?? const []) {
      try {
        out.add(parse(x));
      } catch (e) {
        debugPrint('Пропущена битая запись библиотеки: $e');
      }
    }
    return out;
  }

  Playlist get liked => playlists.firstWhere((p) => p.id == likedId);
  bool isLiked(Track t) => liked.tracks.contains(t);

  void toggleLike(Track t) {
    if (isLiked(t)) {
      liked.tracks.remove(t);
    } else {
      liked.tracks.insert(0, t);
      final before = disliked.length;
      disliked.removeWhere((d) => d.matchKey == t.matchKey); // нравится — значит, больше не скрываем
      if (disliked.length != before) _touch('disliked');
    }
    _touch('pl:$likedId');
    _changed();
  }

  Playlist createPlaylist(String name) {
    final p = Playlist(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name);
    playlists.add(p);
    _touch('pl:${p.id}');
    _changed();
    return p;
  }

  void renamePlaylist(Playlist p, String name) {
    p.name = name;
    _touch('pl:${p.id}');
    _changed();
  }

  void deletePlaylist(Playlist p) {
    if (p.id == likedId) return;
    playlists.remove(p);
    deletedPlaylists[p.id] = _now;
    stamps.remove('pl:${p.id}');
    _changed();
  }

  /// false — трек уже был в плейлисте.
  bool addTo(Playlist p, Track t) {
    if (p.tracks.contains(t)) return false;
    p.tracks.add(t);
    _touch('pl:${p.id}');
    _changed();
    return true;
  }

  void removeFrom(Playlist p, Track t) {
    p.tracks.remove(t);
    _touch('pl:${p.id}');
    _changed();
  }

  void reorder(Playlist p, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    p.tracks.insert(newIndex, p.tracks.removeAt(oldIndex));
    _touch('pl:${p.id}');
    _changed();
  }

  // ---------- «Не нравится» ----------
  // Песня с дизлайком и её исполнитель не попадают в «Мою волну», радио и подборки.
  // В обычном поиске и на странице исполнителя они остаются — найти сам можно всегда.

  /// Треки с дизлайком (свежие в начале) — для списка «Скрытое» в настройках.
  final List<Track> disliked = [];

  static String artistKey(String artist) =>
      Track.normalize(artist.split(RegExp(r',|&| feat\.? | ft\.? | x ', caseSensitive: false)).first);

  Set<String> get _dislikedSongs => {for (final t in disliked) t.matchKey};
  Set<String> get dislikedArtists => {for (final t in disliked) artistKey(t.artist)};

  bool isDisliked(Track t) => _dislikedSongs.contains(t.matchKey);

  /// Можно ли предлагать трек в рекомендациях и радио.
  bool allowedInRecs(Track t) {
    if (_dislikedSongs.contains(t.matchKey)) return false;
    final a = artistKey(t.artist);
    return a.isEmpty || !dislikedArtists.contains(a);
  }

  void dislike(Track t) {
    if (isDisliked(t)) return;
    disliked.insert(0, t);
    _touch('disliked');
    if (isLiked(t)) {
      liked.tracks.remove(t); // не нравится — значит, и не в «Любимом»
      _touch('pl:$likedId');
    }
    _changed();
  }

  void undislike(Track t) {
    disliked.removeWhere((d) => d.matchKey == t.matchKey);
    _touch('disliked');
    _changed();
  }

  void addHistory(Track t) {
    history.remove(t);
    history.insert(0, t);
    historyAt[t.key] = _now;
    if (history.length > historyLimit) {
      for (final old in history.skip(historyLimit)) {
        historyAt.remove(old.key);
      }
      history.removeRange(historyLimit, history.length);
    }
    _changed();
  }

  // ---------- вкус: что слушаешь до конца и что пропускаешь ----------
  // Как у «Моей волны»: дослушал — исполнитель нравится сильнее, пропустил в начале — слабее.

  /// Статистика по исполнителям (ключ — [artistKey]).
  final Map<String, ArtistStat> artists = {};

  static String _primaryName(String artist) =>
      artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();

  ArtistStat _stat(Track t) => artists.putIfAbsent(artistKey(t.artist), () => ArtistStat(_primaryName(t.artist)));

  /// Трек послушали (больше половины или до конца).
  void recordPlay(Track t) {
    if (artistKey(t.artist).isEmpty) return;
    final s = _stat(t);
    s.plays++;
    s.last = _now;
    _changed();
  }

  /// Трек пропустили в самом начале.
  void recordSkip(Track t) {
    if (artistKey(t.artist).isEmpty) return;
    final s = _stat(t);
    s.skips++;
    s.last = _now;
    _changed();
  }

  /// Любимые исполнители, самые любимые первыми: прослушивания до конца, лайки и свежесть
  /// минус пропуски. Исполнители из «Скрытого» сюда не попадают.
  List<String> topArtists([int n = 8]) {
    final s = artistScores();
    final keys = s.keys.where((k) => s[k]!.$2 > 0).toList()..sort((a, b) => s[b]!.$2.compareTo(s[a]!.$2));
    return [for (final k in keys.take(n)) s[k]!.$1];
  }

  /// Насколько нравится каждый исполнитель: artistKey → (имя, оценка). Отрицательная — пропускаешь
  /// или скрыл. Из этого строится профиль тегов (что ты любишь и чего избегаешь).
  Map<String, (String, double)> artistScores() {
    final score = <String, double>{};
    final names = <String, String>{};
    void add(String name, double v) {
      final k = artistKey(name);
      if (k.isEmpty) return;
      names.putIfAbsent(k, () => _primaryName(name));
      score[k] = (score[k] ?? 0) + v;
    }

    final now = _now;
    for (final e in artists.entries) {
      names[e.key] = e.value.name;
      // свежие события весят больше: через месяц вклад падает примерно вдвое
      final ageDays = (now - e.value.last) / 86400000;
      final fresh = 1 / (1 + ageDays / 30);
      score[e.key] = (score[e.key] ?? 0) + (e.value.plays - 1.5 * e.value.skips) * (0.5 + fresh);
    }
    for (final t in liked.tracks.take(100)) {
      add(t.artist, 3);
    }
    for (final (i, t) in history.take(60).indexed) {
      add(t.artist, 1 - i / 60);
    }
    for (final t in disliked) {
      add(t.artist, -6);
    }
    final bad = dislikedArtists;
    return {
      for (final k in score.keys)
        if (names[k] != null) k: (names[k]!, bad.contains(k) ? min(score[k]!, -3.0) : score[k]!),
    };
  }

  // ---------- свои теги ----------

  /// Свои теги исполнителей (artistKey → теги): главнее автоматических.
  final Map<String, List<String>> userTags = {};

  String artistKeyOf(String artist) => artistKey(artist);

  /// Задать свои теги исполнителя. Пустой список — вернуть автоматические.
  void setUserTags(String artist, List<String> tags) {
    final k = artistKey(artist);
    if (k.isEmpty) return;
    final clean = [
      for (final t in tags)
        if (t.trim().isNotEmpty) t.trim().toLowerCase(),
    ].toSet().toList();
    if (clean.isEmpty) {
      userTags.remove(k);
    } else {
      userTags[k] = clean;
    }
    _touch('userTags');
    _changed();
  }

  /// Исполнителя часто пропускают — в радио его лучше не ставить.
  bool oftenSkipped(String artist) {
    final s = artists[artistKey(artist)];
    return s != null && s.skips >= 3 && s.skips > 2 * s.plays;
  }

  void _changed() {
    notifyListeners();
    // сохраняем не чаще раза в секунду
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _save);
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'playlists': playlists.map((p) => p.toJson()).toList(),
        'history': history.map((t) => t.toJson()).toList(),
        'disliked': disliked.map((t) => t.toJson()).toList(),
        'stamps': stamps,
        'deleted': deletedPlaylists,
        'historyAt': historyAt,
        'artists': {for (final e in artists.entries) e.key: e.value.toJson()},
        'userTags': userTags,
      };

  Future<void> _save() async {
    await _store.write(jsonEncode(toJson()));
    onSaved?.call();
  }

  /// Заменить содержимое версией после слияния с облаком.
  void replaceWith(Map<String, dynamic> j) {
    playlists
      ..clear()
      ..addAll(_each(j['playlists'], (p) => Playlist.fromJson(Map<String, dynamic>.from(p))));
    history
      ..clear()
      ..addAll(_each(j['history'], (t) => Track.fromJson(Map<String, dynamic>.from(t))));
    disliked
      ..clear()
      ..addAll(_each(j['disliked'], (t) => Track.fromJson(Map<String, dynamic>.from(t))));
    stamps.clear();
    deletedPlaylists.clear();
    historyAt.clear();
    artists.clear();
    userTags.clear();
    _readMeta(j);
    _ensureLiked();
    _changed();
  }

  /// Слить две версии библиотеки (эта и из облака) так, чтобы ничего не потерялось:
  /// у каждого плейлиста и «Скрытого» побеждает более свежая версия, удалённые плейлисты
  /// остаются удалёнными, история объединяется по времени прослушивания, счётчики — по максимуму.
  static Map<String, dynamic> merge(Map<String, dynamic> a, Map<String, dynamic> b) {
    Map<String, int> maxMap(Map<String, int> x, Map<String, int> y) {
      final out = Map.of(x);
      y.forEach((k, v) => out[k] = (out[k] ?? v) > v ? out[k]! : v);
      return out;
    }

    List list(dynamic v) => v is List ? v : const [];

    final stA = _ints(a['stamps']), stB = _ints(b['stamps']);
    final stamps = maxMap(stA, stB);
    final deleted = maxMap(_ints(a['deleted']), _ints(b['deleted']));

    // плейлисты: порядок — как в первой версии, новые из второй — в конец
    final plA = {for (final p in list(a['playlists'])) '${p['id']}': p};
    final plB = {for (final p in list(b['playlists'])) '${p['id']}': p};
    final ids = [...plA.keys, ...plB.keys.where((k) => !plA.containsKey(k))];
    final playlists = <dynamic>[];
    for (final id in ids) {
      final ta = stA['pl:$id'] ?? 0, tb = stB['pl:$id'] ?? 0;
      final p = plA[id] == null
          ? plB[id]
          : plB[id] == null
              ? plA[id]
              : (tb > ta ? plB[id] : plA[id]);
      final changed = ta > tb ? ta : tb;
      // удалён позже последнего изменения — значит, удалён («Любимое» удалить нельзя)
      if (id != likedId && (deleted[id] ?? 0) > changed) continue;
      playlists.add(p);
    }
    for (final id in deleted.keys) {
      if ((deleted[id] ?? 0) > (stamps['pl:$id'] ?? 0)) stamps.remove('pl:$id');
    }

    final disliked = (stB['disliked'] ?? 0) > (stA['disliked'] ?? 0) ? list(b['disliked']) : list(a['disliked']);
    final userTags = (stB['userTags'] ?? 0) > (stA['userTags'] ?? 0) ? b['userTags'] : a['userTags'];

    // история: объединение по времени прослушивания
    final at = maxMap(_ints(a['historyAt']), _ints(b['historyAt']));
    final byKey = <String, dynamic>{};
    for (final t in [...list(a['history']), ...list(b['history'])]) {
      byKey.putIfAbsent('${t['source']}:${t['id']}', () => t);
    }
    final keys = byKey.keys.toList()..sort((x, y) => (at[y] ?? 0).compareTo(at[x] ?? 0));
    final kept = keys.take(historyLimit).toList();

    // статистика исполнителей: по максимуму (счётчики только растут)
    final arts = <String, dynamic>{};
    for (final src in [a['artists'], b['artists']]) {
      if (src is! Map) continue;
      for (final e in src.entries) {
        final v = Map<String, dynamic>.from(e.value as Map);
        final old = arts['${e.key}'] as Map<String, dynamic>?;
        if (old == null) {
          arts['${e.key}'] = v;
          continue;
        }
        int mx(String f) {
          final x = (old[f] as num?)?.toInt() ?? 0, y = (v[f] as num?)?.toInt() ?? 0;
          return x > y ? x : y;
        }

        arts['${e.key}'] = {'n': old['n'] ?? v['n'], 'p': mx('p'), 's': mx('s'), 't': mx('t')};
      }
    }

    return {
      'version': 2,
      'playlists': playlists,
      'history': [for (final k in kept) byKey[k]],
      'disliked': disliked,
      'stamps': stamps,
      'deleted': deleted,
      'historyAt': {for (final k in kept) if (at[k] != null) k: at[k]},
      'artists': arts,
      'userTags': userTags is Map ? userTags : const {},
    };
  }
}

/// Сколько раз исполнителя дослушали и пропустили.
class ArtistStat {
  final String name;
  int plays;
  int skips;
  int last; // мс, последнее событие
  ArtistStat(this.name, {this.plays = 0, this.skips = 0, this.last = 0});

  Map<String, dynamic> toJson() => {'n': name, 'p': plays, 's': skips, 't': last};
  factory ArtistStat.fromJson(Map<String, dynamic> j) => ArtistStat('${j['n'] ?? ''}',
      plays: (j['p'] as num?)?.toInt() ?? 0,
      skips: (j['s'] as num?)?.toInt() ?? 0,
      last: (j['t'] as num?)?.toInt() ?? 0);
}
