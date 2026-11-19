import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import 'net.dart';
import 'source.dart';

/// Звук (zvuk.com, бывший СберЗвук). Неофициальный API — тот же, что использует их сайт
/// (так же устроены открытые клиенты, например github.com/trudenboy/zvuk-music).
///
/// Без входа сайт выдаёт гостевой токен: с ним работают поиск и полные треки в 128 кбит/с.
/// С токеном своего аккаунта и подпиской — 320 кбит/с.
class ZvukSource extends MusicSource {
  static const _graphql = 'https://zvuk.com/api/v1/graphql';
  static const _profile = 'https://zvuk.com/api/tiny/profile';
  static const _guestKey = 'zvuk_guest_token';

  /// Токен своего аккаунта (необязательно). Если пусто — используем гостевой.
  String? userToken;
  String? _guestToken;
  ZvukSource(this.userToken);

  @override
  String get id => 'zvuk';
  @override
  String get name => 'Звук';
  @override
  bool get isConfigured => !Net.proxyMissing;

  // Поля трека и альбома — одинаковые во всех запросах.
  static const _trackFields = 'id title duration explicit artists { id title } release { id title date image { src } }';
  static const _releaseFields = 'id title date type explicit image { src } artists { id title }';

  static const _searchQuery = '''
query search(\$query: String, \$limit: Int) {
  search(query: \$query) {
    tracks(limit: \$limit) { items { $_trackFields } }
  }
}''';

  static const _searchReleasesQuery = '''
query searchReleases(\$query: String, \$limit: Int) {
  search(query: \$query) {
    releases(limit: \$limit) { items { $_releaseFields } }
  }
}''';

  static const _searchArtistsQuery = r'''
query searchArtists($query: String, $limit: Int) {
  search(query: $query) {
    artists(limit: $limit) { items { id title image { src } } }
  }
}''';

  static const _releaseQuery = '''
query getReleases(\$ids: [ID!]!) {
  getReleases(ids: \$ids) {
    $_releaseFields
    tracks { $_trackFields }
  }
}''';

  static const _artistQuery = '''
query getArtists(\$ids: [ID!]!) {
  getArtists(ids: \$ids) {
    id title image { src }
    popularTracks(offset: 0, limit: 20) { $_trackFields }
    releases(offset: 0, limit: 60) { $_releaseFields }
  }
}''';

  static const _streamQuery = r'''
query getStream($ids: [ID!]!) {
  mediaContents(ids: $ids) {
    ... on Track { stream { high mid } }
  }
}''';

  Map<String, String> _headers(String token) => {
        'X-Auth-Token': token,
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        if (!kIsWeb) ...{
          'User-Agent': userAgent,
          'Referer': 'https://zvuk.com/',
          'Origin': 'https://zvuk.com',
        },
      };

  /// Гостевой токен: сайт выдаёт его любому посетителю. Запоминаем, чтобы не просить каждый раз.
  Future<String> _token({bool refresh = false}) async {
    if (userToken?.isNotEmpty == true) return userToken!;
    if (_guestToken != null && !refresh) return _guestToken!;
    final prefs = await SharedPreferences.getInstance();
    if (!refresh && prefs.getString(_guestKey) != null) return _guestToken = prefs.getString(_guestKey)!;
    final res = await Net.client.get(Net.wrap(Uri.parse(_profile)), headers: {
      'Accept': 'application/json',
      if (!kIsWeb) 'User-Agent': userAgent,
    });
    if (res.statusCode != 200) throw Exception('Звук: не удалось получить гостевой доступ (HTTP ${res.statusCode})');
    final token = ((jsonDecode(res.body) as Map)['result'] as Map?)?['token'];
    if (token is! String || token.isEmpty) throw Exception('Звук: сайт не выдал гостевой токен');
    await prefs.setString(_guestKey, token);
    return _guestToken = token;
  }

  Future<Map> _gql(String operation, String query, Map<String, dynamic> variables) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _token(refresh: attempt > 0);
      final res = await Net.client.post(
        Net.wrap(Uri.parse(_graphql)),
        headers: _headers(token),
        body: jsonEncode({'operationName': operation, 'query': query, 'variables': variables}),
      );
      // гостевой токен протух — берём новый (свой токен пользователя не трогаем)
      if ((res.statusCode == 401 || res.statusCode == 403) && userToken?.isNotEmpty != true && attempt == 0) continue;
      if (res.statusCode == 401 || res.statusCode == 403) throw Exception('Звук: токен не подошёл');
      if (res.statusCode == 451) throw Exception('Звук: недоступно в этом регионе');
      if (res.statusCode != 200) throw Exception('Звук: HTTP ${res.statusCode}');
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final errors = body['errors'] as List?;
      if (body['data'] == null && errors != null && errors.isNotEmpty) {
        throw Exception('Звук: ${(errors.first as Map)['message']}');
      }
      return (body['data'] as Map?) ?? {};
    }
    throw Exception('Звук: доступ запрещён');
  }

  /// Токен из вставленного текста: можно вставить сам токен или всю страницу
  /// zvuk.com/api/tiny/profile целиком — найдём поле "token" сами.
  static String extractToken(String pasted) {
    final s = pasted.trim();
    final m = RegExp(r'"token"\s*:\s*"([^"]+)"').firstMatch(s);
    if (m != null) return m.group(1)!;
    return s.replaceAll(RegExp(r'^["\s]+|["\s]+$'), '');
  }

  /// Проверить токен: вошёл ли человек в аккаунт или это гостевой доступ.
  /// Возвращает имя (если Звук его отдал) или пустую строку; null — гостевой токен.
  Future<String?> checkLogin(String token) async {
    final res = await Net.client.get(Net.wrap(Uri.parse(_profile)), headers: {
      'X-Auth-Token': token,
      'Accept': 'application/json',
      if (!kIsWeb) 'User-Agent': userAgent,
    });
    if (res.statusCode == 401 || res.statusCode == 403) throw Exception('Звук: токен не подошёл');
    if (res.statusCode != 200) throw Exception('Звук: HTTP ${res.statusCode}');
    final r = ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['result'] as Map?) ?? {};
    final profile = (r['profile'] as Map?) ?? {};
    final anonymous = r['is_anonymous'] == true || profile['is_anonymous'] == true;
    if (anonymous) return null;
    return '${profile['name'] ?? r['name'] ?? ''}'.trim();
  }

  static String? coverUrl(String? src, {int size = 300}) {
    if (src == null || src.isEmpty) return null;
    final full = src.startsWith('/') ? 'https://zvuk.com$src' : src;
    final u = Uri.parse(full.replaceAll('{size}', '${size}x$size'));
    return u.replace(queryParameters: {...u.queryParameters, 'size': '${size}x$size'}).toString();
  }

  static int? _year(dynamic date) {
    final d = '${date ?? ''}';
    return d.length >= 4 ? int.tryParse(d.substring(0, 4)) : null;
  }

  static String _artists(dynamic list) =>
      ((list as List?) ?? []).map((a) => (a as Map)['title']).whereType<String>().join(', ');

  /// [fallbackRelease] — для треков внутри альбома, у которых release может не прийти.
  Track _parse(Map j, {Map? fallbackRelease}) {
    final release = (j['release'] as Map?) ?? fallbackRelease ?? {};
    final artists = (j['artists'] as List?) ?? [];
    return Track(
      source: id,
      id: '${j['id']}',
      title: '${j['title'] ?? ''}',
      artist: _artists(artists),
      album: release['title'] as String?,
      year: _year(release['date']),
      coverUrl: coverUrl((release['image'] as Map?)?['src'] as String?),
      duration: Duration(seconds: (j['duration'] as num?)?.toInt() ?? 0),
      explicit: j['explicit'] == true,
      extra: {
        if (release['id'] != null) 'albumId': '${release['id']}',
        if (artists.isNotEmpty && (artists.first as Map)['id'] != null) 'artistId': '${(artists.first as Map)['id']}',
      },
    );
  }

  AlbumRef _parseRelease(Map r) => AlbumRef(
        source: id,
        id: '${r['id']}',
        title: '${r['title'] ?? ''}',
        artist: _artists(r['artists']),
        coverUrl: coverUrl((r['image'] as Map?)?['src'] as String?),
        year: _year(r['date']),
        explicit: r['explicit'] == true,
        type: r['type'] as String?,
      );

  ArtistRef _parseArtist(Map a) => ArtistRef(
        source: id,
        id: '${a['id']}',
        name: '${a['title'] ?? ''}',
        imageUrl: coverUrl((a['image'] as Map?)?['src'] as String?),
      );

  @override
  bool get hasCatalog => true;

  @override
  Future<List<AlbumRef>> searchAlbums(String query) async {
    final data = await _gql('searchReleases', _searchReleasesQuery, {'query': query, 'limit': 20});
    final items = ((((data['search'] as Map?)?['releases']) as Map?)?['items'] as List?) ?? [];
    return items.whereType<Map>().map(_parseRelease).toList();
  }

  @override
  Future<List<ArtistRef>> searchArtists(String query) async {
    final data = await _gql('searchArtists', _searchArtistsQuery, {'query': query, 'limit': 10});
    final items = ((((data['search'] as Map?)?['artists']) as Map?)?['items'] as List?) ?? [];
    return items.whereType<Map>().map(_parseArtist).toList();
  }

  @override
  Future<AlbumInfo?> album(String albumId) async {
    final data = await _gql('getReleases', _releaseQuery, {
      'ids': [albumId]
    });
    final list = (data['getReleases'] as List?) ?? [];
    if (list.isEmpty || list.first is! Map) return null;
    final r = list.first as Map;
    final artists = (r['artists'] as List?) ?? [];
    return AlbumInfo(
      _parseRelease(r),
      ((r['tracks'] as List?) ?? []).whereType<Map>().map((t) => _parse(t, fallbackRelease: r)).toList(),
      artist: artists.isEmpty ? null : _parseArtist(artists.first as Map),
    );
  }

  static const _artistReleasesQuery = '''
query getArtists(\$ids: [ID!]!) {
  getArtists(ids: \$ids) { releases(offset: 0, limit: 200) { id date } }
}''';

  static const _releasesTracksQuery = '''
query getReleases(\$ids: [ID!]!) {
  getReleases(ids: \$ids) { $_releaseFields tracks { $_trackFields } }
}''';

  /// Отдельного списка «все треки» у Звука нет — собираем их из всех альбомов и синглов
  /// исполнителя, от новых к старым, по 8 релизов за порцию.
  @override
  Future<TrackPage> artistTracks(String artistId, {Object? cursor}) async {
    const batch = 8;
    List<String> ids;
    int offset;
    if (cursor is (List<String>, int)) {
      (ids, offset) = cursor;
    } else {
      final data = await _gql('getArtists', _artistReleasesQuery, {
        'ids': [artistId]
      });
      final list = (data['getArtists'] as List?) ?? [];
      final releases = list.isEmpty ? <Map>[] : (((list.first as Map)['releases'] as List?) ?? []).whereType<Map>().toList();
      releases.sort((a, b) => '${b['date'] ?? ''}'.compareTo('${a['date'] ?? ''}'));
      ids = releases.map((r) => '${r['id']}').toList();
      offset = 0;
    }
    if (offset >= ids.length) return const TrackPage([], null);
    final part = ids.sublist(offset, (offset + batch).clamp(0, ids.length));
    final data = await _gql('getReleases', _releasesTracksQuery, {'ids': part});
    final tracks = <Track>[];
    final seen = <String>{};
    for (final r in ((data['getReleases'] as List?) ?? []).whereType<Map>()) {
      for (final t in ((r['tracks'] as List?) ?? []).whereType<Map>()) {
        // только треки этого исполнителя (в сборниках бывают чужие) и без повторов
        final artists = ((t['artists'] as List?) ?? []).whereType<Map>().map((a) => '${a['id']}');
        if (!artists.contains(artistId) || !seen.add('${t['id']}')) continue;
        tracks.add(_parse(t, fallbackRelease: r));
      }
    }
    final next = offset + batch;
    return TrackPage(tracks, next < ids.length ? (ids, next) : null);
  }

  @override
  Future<ArtistInfo?> artist(String artistId) async {
    final data = await _gql('getArtists', _artistQuery, {
      'ids': [artistId]
    });
    final list = (data['getArtists'] as List?) ?? [];
    if (list.isEmpty || list.first is! Map) return null;
    final a = list.first as Map;
    final releases = ((a['releases'] as List?) ?? []).whereType<Map>().map(_parseRelease).toList()
      ..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0)); // новые сверху
    return ArtistInfo(
      _parseArtist(a),
      topTracks: ((a['popularTracks'] as List?) ?? []).whereType<Map>().map((t) => _parse(t)).toList(),
      albums: releases,
    );
  }

  @override
  Future<List<Track>> search(String query) async {
    final data = await _gql('search', _searchQuery, {'query': query, 'limit': 20});
    final items = ((((data['search'] as Map?)?['tracks']) as Map?)?['items'] as List?) ?? [];
    return items.whereType<Map>().map(_parse).toList();
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async {
    final data = await _gql('getStream', _streamQuery, {
      'ids': [track.id]
    });
    final contents = (data['mediaContents'] as List?) ?? [];
    final stream = contents.isEmpty ? null : (contents.first as Map?)?['stream'] as Map?;
    // 320 кбит/с — с подпиской, 128 кбит/с — для всех
    final url = (stream?['high'] as String?)?.isNotEmpty == true ? stream!['high'] : stream?['mid'];
    if (url is! String || url.isEmpty) throw Exception('Звук: трек недоступен для прослушивания');
    return StreamInfo(Uri.parse(url));
  }
}
