import 'dart:async';

import '../models/track.dart';
import '../sources/net.dart';
import '../sources/source.dart';
import 'lyrics.dart';
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

  /// Что получилось на каждой площадке при последнем неудачном поиске альбома/исполнителя —
  /// чтобы честно написать пользователю, где искали и почему не нашли.
  String lastReport = '';

  /// Все площадки с каталогом — и подключённые, и нет (о неподключённых пишем в отчёте).
  List<MusicSource> get _allCatalogSources {
    final list = search.sources.where((s) => s.hasCatalog && (s.id != 'local' || s.isConfigured)).toList();
    list.sort((a, b) => _rank(a.id).compareTo(_rank(b.id)));
    return list;
  }

  static String _primaryArtist(String a) => a.split(RegExp(r',|&| feat\.? | ft\.? | x ', caseSensitive: false)).first.trim();

  /// Ключи для сравнения: название без пометок и все варианты исполнителя.
  /// «LAZZY2WICE - TWISTED METAL» от загрузившего на SoundCloud → исполнитель берётся и из названия.
  static (Set<String>, String) matchKeys(Track t) {
    var title = t.title;
    final artists = <String>{Track.normalize(_primaryArtist(t.artist))};
    final dash = RegExp(r'\s[-–—]\s').firstMatch(title);
    if (dash != null) {
      artists.add(Track.normalize(_primaryArtist(title.substring(0, dash.start))));
      title = title.substring(dash.end);
    }
    artists.removeWhere((a) => a.isEmpty);
    return (artists, Track.normalize(LyricsService.cleanTitle(title)));
  }

  static bool sameSong(Track f, Set<String> artists, String title) {
    final ft = Track.normalize(LyricsService.cleanTitle(f.title));
    final titleOk = ft == title || (title.length >= 4 && (ft.contains(title) || title.contains(ft) && ft.length >= 4));
    if (!titleOk) return false;
    final fa = Track.normalize(f.artist);
    // название в «Исполнитель - Песня» тоже может содержать исполнителя
    final hay = '$fa ${Track.normalize(f.title)}';
    return artists.any((a) => fa == a || hay.contains(a) || (fa.isNotEmpty && a.contains(fa)));
  }

  /// Альбом, в котором есть этот трек.
  Future<AlbumInfo?> albumFor(Track t) async {
    final report = <String>[];
    final own = sourceById(t.source);
    if (own != null && own.hasCatalog && t.albumId != null) {
      final a = await _safe(() => _albumOf(own, t.albumId!));
      if (a != null && a.tracks.isNotEmpty) return a;
    }
    final (artists, title) = matchKeys(t);
    final artistName = _primaryArtist(t.artist);
    final cleanTitle = LyricsService.cleanTitle(t.title.contains(RegExp(r'\s[-–—]\s'))
        ? t.title.substring(RegExp(r'\s[-–—]\s').firstMatch(t.title)!.end)
        : t.title);

    for (final s in _allCatalogSources) {
      if (s.id == t.source && t.albumId != null) continue; // уже пробовали выше
      if (!s.isConfigured) {
        report.add('${s.name}: не подключён');
        continue;
      }
      try {
        Track? match;
        // сначала «исполнитель + название», потом одно название
        for (final q in ['$artistName $cleanTitle', cleanTitle]) {
          final found = await s.search(q).timeout(SearchService.timeout);
          match = found.where((f) => f.albumId != null && sameSong(f, artists, title)).firstOrNull;
          if (match != null) break;
        }
        if (match == null) {
          report.add('${s.name}: песни с альбомом не нашлось');
          continue;
        }
        final a = await _albumOf(s, match.albumId!).timeout(SearchService.timeout);
        if (a != null && a.tracks.isNotEmpty) return a;
        report.add('${s.name}: альбом не открылся');
      } catch (e) {
        report.add('${s.name}: ${Net.describe(e)}');
      }
    }
    lastReport = report.join('\n');
    return null;
  }

  /// Страница исполнителя этого трека.
  Future<ArtistInfo?> artistFor(Track t) async {
    final own = sourceById(t.source);
    if (own != null && own.hasCatalog && t.artistId != null) {
      final a = await _safe(() => _artistOf(own, t.artistId!));
      if (a != null) return a;
    }
    // имя из поля исполнителя и из названия вида «Исполнитель - Песня»
    final names = <String>[_primaryArtist(t.artist)];
    final dash = RegExp(r'\s[-–—]\s').firstMatch(t.title);
    if (dash != null) names.add(_primaryArtist(t.title.substring(0, dash.start)));
    final report = <String>[];
    for (final name in names.toSet()) {
      final a = await artistByName(name, report: report);
      if (a != null) return a;
    }
    lastReport = report.toSet().join('\n');
    return null;
  }

  /// Исполнитель по имени на площадках с каталогом: точное совпадение имени, иначе близкое.
  Future<ArtistInfo?> artistByName(String name, {List<String>? report}) async {
    final key = Track.normalize(name);
    if (key.isEmpty) return null;
    for (final s in _allCatalogSources) {
      if (!s.isConfigured) {
        report?.add('${s.name}: не подключён');
        continue;
      }
      try {
        final found = await s.searchArtists(name).timeout(SearchService.timeout);
        final match = found.where((a) => Track.normalize(a.name) == key).firstOrNull ??
            found.where((a) {
              final n = Track.normalize(a.name);
              return n.isNotEmpty && (n.contains(key) || key.contains(n)) && (n.length - key.length).abs() <= 3;
            }).firstOrNull;
        if (match == null) {
          report?.add('${s.name}: исполнителя не нашлось');
          continue;
        }
        final a = await _artistOf(s, match.id).timeout(SearchService.timeout);
        if (a != null) return a;
        report?.add('${s.name}: страница не открылась');
      } catch (e) {
        report?.add('${s.name}: ${Net.describe(e)}');
      }
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
