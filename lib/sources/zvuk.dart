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

  static const _searchQuery = r'''
query search($query: String, $limit: Int) {
  search(query: $query) {
    tracks(limit: $limit) {
      items {
        id title duration explicit
        artists { title }
        release { title date image { src } }
      }
    }
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

  static String? coverUrl(String? src, {int size = 300}) {
    if (src == null || src.isEmpty) return null;
    final full = src.startsWith('/') ? 'https://zvuk.com$src' : src;
    final u = Uri.parse(full.replaceAll('{size}', '${size}x$size'));
    return u.replace(queryParameters: {...u.queryParameters, 'size': '${size}x$size'}).toString();
  }

  Track _parse(Map j) {
    final release = (j['release'] as Map?) ?? {};
    final date = '${release['date'] ?? ''}';
    return Track(
      source: id,
      id: '${j['id']}',
      title: '${j['title'] ?? ''}',
      artist: ((j['artists'] as List?) ?? []).map((a) => (a as Map)['title']).whereType<String>().join(', '),
      album: release['title'] as String?,
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      coverUrl: coverUrl((release['image'] as Map?)?['src'] as String?),
      duration: Duration(seconds: (j['duration'] as num?)?.toInt() ?? 0),
      explicit: j['explicit'] == true,
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
