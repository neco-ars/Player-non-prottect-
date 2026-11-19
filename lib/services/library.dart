import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  Library._(this._store);

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
      }
    } catch (e) {
      debugPrint('library.json повреждён, начинаем заново: $e');
      // сохраняем испорченный файл рядом, чтобы его можно было восстановить вручную
      if (raw != null) await store.backup(raw);
    }
    if (!lib.playlists.any((p) => p.id == likedId)) {
      lib.playlists.insert(0, Playlist(id: likedId, name: 'Любимое'));
    }
    return lib;
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
      disliked.removeWhere((d) => d.matchKey == t.matchKey); // нравится — значит, больше не скрываем
    }
    _changed();
  }

  Playlist createPlaylist(String name) {
    final p = Playlist(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name);
    playlists.add(p);
    _changed();
    return p;
  }

  void renamePlaylist(Playlist p, String name) {
    p.name = name;
    _changed();
  }

  void deletePlaylist(Playlist p) {
    if (p.id == likedId) return;
    playlists.remove(p);
    _changed();
  }

  /// false — трек уже был в плейлисте.
  bool addTo(Playlist p, Track t) {
    if (p.tracks.contains(t)) return false;
    p.tracks.add(t);
    _changed();
    return true;
  }

  void removeFrom(Playlist p, Track t) {
    p.tracks.remove(t);
    _changed();
  }

  void reorder(Playlist p, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    p.tracks.insert(newIndex, p.tracks.removeAt(oldIndex));
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
    if (isLiked(t)) liked.tracks.remove(t); // не нравится — значит, и не в «Любимом»
    _changed();
  }

  void undislike(Track t) {
    disliked.removeWhere((d) => d.matchKey == t.matchKey);
    _changed();
  }

  void addHistory(Track t) {
    history.remove(t);
    history.insert(0, t);
    if (history.length > historyLimit) history.removeRange(historyLimit, history.length);
    _changed();
  }

  void _changed() {
    notifyListeners();
    // сохраняем не чаще раза в секунду
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _save);
  }

  Future<void> _save() async {
    final data = jsonEncode({
      'version': 1,
      'playlists': playlists.map((p) => p.toJson()).toList(),
      'history': history.map((t) => t.toJson()).toList(),
      'disliked': disliked.map((t) => t.toJson()).toList(),
    });
    await _store.write(data);
  }
}
