import 'dart:async';

import '../models/track.dart';
import '../sources/net.dart';
import '../sources/source.dart';
import 'search_service.dart';

/// Альбомы и исполнители со всех площадок.
/// Если у площадки трека нет альбомов (YouTube, Audiomack) или трек без альбома,
/// находим ту же песню на площадке с каталогом и берём альбом оттуда.
class CatalogService {
  final SearchService search;
  CatalogService(this.search);

  /// Площадки с альбомами, в порядке предпочтения для запасного поиска.
  static const _preferred = ['zvuk', 'yandex', 'soundcloud', 'audius', 'local'];

  List<MusicSource> get _catalogSources {
    final list = search.sources.where((s) => s.hasCatalog && s.isConfigured).toList();
    list.sort((a, b) => _rank(a.id).compareTo(_rank(b.id)));
    return list;
  }

  static int _rank(String id) {
    final i = _preferred.indexOf(id);
    return i < 0 ? 99 : i;
  }

  MusicSource? sourceById(String id) => search.sources.where((s) => s.id == id).firstOrNull;

  // Открытые альбомы и исполнители держим 15 минут: «назад» и повторный переход — без сети.
  static const _ttl = Duration(minutes: 15);
  final Map<String, (DateTime, AlbumInfo)> _albums = {};
  final Map<String, (DateTime, ArtistInfo)> _artists = {};

  Future<AlbumInfo?> _albumOf(MusicSource s, String id) async {
    final key = '${s.id}:$id';
    final hit = _albums[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) return hit.$2;
    final a = await s.album(id);
    if (a != null) {
      _albums[key] = (DateTime.now(), a);
      if (_albums.length > 30) _albums.remove(_albums.keys.first);
    }
    return a;
  }

  Future<ArtistInfo?> _artistOf(MusicSource s, String id) async {
    final key = '${s.id}:$id';
    final hit = _artists[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) return hit.$2;
    final a = await s.artist(id);
    if (a != null) {
      _artists[key] = (DateTime.now(), a);
      if (_artists.length > 30) _artists.remove(_artists.keys.first);
    }
    return a;
  }

  Future<AlbumInfo?> album(AlbumRef ref) async {
    final s = sourceById(ref.source);
    return s == null ? null : _albumOf(s, ref.id);
  }

  Future<ArtistInfo?> artist(ArtistRef ref) async {
    final s = sourceById(ref.source);
    return s == null ? null : _artistOf(s, ref.id);
  }

  /// Альбом, в котором есть этот трек.
  Future<AlbumInfo?> albumFor(Track t) async {
    final own = sourceById(t.source);
    if (own != null && own.hasCatalog && t.albumId != null) {
      final a = await _safe(() => _albumOf(own, t.albumId!));
      if (a != null && a.tracks.isNotEmpty) return a;
    }
    // ищем ту же песню там, где у треков есть альбомы
    for (final s in _catalogSources.where((s) => s.id != t.source)) {
      final found = await _safeList(() => s.search('${t.artist} ${t.title}'));
      final match = found.where((f) => f.matchKey == t.matchKey && f.albumId != null).firstOrNull;
      if (match == null) continue;
      final a = await _safe(() => _albumOf(s, match.albumId!));
      if (a != null && a.tracks.isNotEmpty) return a;
    }
    return null;
  }

  /// Страница исполнителя этого трека.
  Future<ArtistInfo?> artistFor(Track t) async {
    final own = sourceById(t.source);
    if (own != null && own.hasCatalog && t.artistId != null) {
      final a = await _safe(() => _artistOf(own, t.artistId!));
      if (a != null) return a;
    }
    final name = t.artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();
    return artistByName(name, exclude: t.source);
  }

  /// Исполнитель по имени: точное совпадение имени на площадке с каталогом.
  Future<ArtistInfo?> artistByName(String name, {String? exclude}) async {
    final key = Track.normalize(name);
    for (final s in _catalogSources.where((s) => s.id != exclude)) {
      final found = await _safeArtists(() => s.searchArtists(name));
      final match = found.where((a) => Track.normalize(a.name) == key).firstOrNull;
      if (match == null) continue;
      final a = await _safe(() => _artistOf(s, match.id));
      if (a != null) return a;
    }
    return null;
  }

  /// Поиск альбомов по всем площадкам; результаты — по мере ответа площадок.
  Stream<CatalogResult<AlbumRef>> searchAlbums(String q) => _merged(q, (s) => s.searchAlbums(q));

  Stream<CatalogResult<ArtistRef>> searchArtists(String q) => _merged(q, (s) => s.searchArtists(q));

  Stream<CatalogResult<T>> _merged<T>(String q, Future<List<T>> Function(MusicSource) fetch) {
    final sources = _catalogSources;
    final ctrl = StreamController<CatalogResult<T>>();
    final lists = List<List<T>?>.filled(sources.length, null);
    final errors = <String, String>{};
    if (sources.isEmpty) {
      ctrl.add(CatalogResult(const [], const {}, const []));
      ctrl.close();
      return ctrl.stream;
    }
    void emit() {
      final pending = [for (var i = 0; i < sources.length; i++) if (lists[i] == null) sources[i].name];
      // чередуем площадки, чтобы ни одна не забивала выдачу
      final out = <T>[];
      final maxLen = lists.fold<int>(0, (m, l) => (l?.length ?? 0) > m ? l!.length : m);
      for (var i = 0; i < maxLen; i++) {
        for (final l in lists) {
          if (l != null && i < l.length) out.add(l[i]);
        }
      }
      ctrl.add(CatalogResult(out, Map.of(errors), pending));
      if (pending.isEmpty) ctrl.close();
    }

    for (var i = 0; i < sources.length; i++) {
      fetch(sources[i]).timeout(SearchService.timeout).then((r) => lists[i] = r, onError: (Object e) {
        errors[sources[i].name] = Net.describe(e);
        lists[i] = <T>[];
      }).whenComplete(emit);
    }
    return ctrl.stream;
  }

  static Future<X?> _safe<X>(Future<X?> Function() f) async {
    try {
      return await f().timeout(SearchService.timeout);
    } catch (_) {
      return null;
    }
  }

  static Future<List<Track>> _safeList(Future<List<Track>> Function() f) async => (await _safe(f)) ?? const [];
  static Future<List<ArtistRef>> _safeArtists(Future<List<ArtistRef>> Function() f) async =>
      (await _safe(f)) ?? const [];
}

class CatalogResult<T> {
  final List<T> items;
  final Map<String, String> errors;
  final List<String> pending;
  const CatalogResult(this.items, this.errors, this.pending);
  bool get done => pending.isEmpty;
}
