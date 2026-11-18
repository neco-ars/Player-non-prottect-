import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import 'net.dart';
import 'source.dart';

/// SoundCloud: тот же публичный API, через который работает их сайт.
class SoundCloudSource extends MusicSource {
  String? _clientId;

  // В браузере User-Agent задать нельзя — его подставляет прокси.
  static Map<String, String> get _ua => kIsWeb ? const {} : const {'User-Agent': userAgent};

  @override
  String get id => 'soundcloud';
  @override
  String get name => 'SoundCloud';
  @override
  bool get isConfigured => !Net.proxyMissing;

  static const _prefKey = 'soundcloud_client_id';

  /// client_id берётся из JS сайта SoundCloud и иногда меняется,
  /// поэтому при ошибке 401/403 получаем его заново.
  /// Найденный ключ запоминаем на устройстве: иначе каждый запуск скачивал бы
  /// главную страницу SoundCloud и несколько мегабайт их скриптов.
  Future<String> _getClientId({bool refresh = false}) async {
    if (_clientId != null && !refresh) return _clientId!;
    final prefs = await SharedPreferences.getInstance();
    if (!refresh) {
      final saved = prefs.getString(_prefKey);
      if (saved != null) return _clientId = saved;
    }
    final id = await _scrapeClientId();
    await prefs.setString(_prefKey, id);
    return _clientId = id;
  }

  Future<String> _scrapeClientId() async {
    final page = await Net.client.get(Net.wrap(Uri.https('soundcloud.com', '/')), headers: _ua);
    final idRe = RegExp(r'client_id\s*[:=]\s*"([0-9a-zA-Z]{32})"');
    // иногда client_id лежит прямо в HTML
    final inline = idRe.firstMatch(page.body);
    if (inline != null) return inline.group(1)!;

    final scripts = RegExp(r'src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"')
        .allMatches(page.body)
        .map((m) => m.group(1)!)
        .toSet()
        .toList()
        .reversed; // client_id обычно в последних скриптах
    for (final src in scripts) {
      final js = await Net.client.get(Net.wrap(Uri.parse(src)), headers: _ua);
      final m = idRe.firstMatch(js.body);
      if (m != null) return m.group(1)!;
    }
    // подробности — чтобы было понятно, что вернул SoundCloud (например, проверку на бота)
    final title = RegExp(r'<title>([^<]{0,60})').firstMatch(page.body)?.group(1)?.trim();
    throw Exception('не удалось получить client_id '
        '(HTTP ${page.statusCode}, скриптов: ${scripts.length}, ${page.body.length} байт'
        '${title == null ? '' : ', страница: «$title»'})');
  }

  Future<http.Response> _get(String url, [Map<String, String> params = const {}]) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final cid = await _getClientId(refresh: attempt > 0);
      final uri = Uri.parse(url).replace(queryParameters: {...params, 'client_id': cid});
      final res = await Net.client.get(Net.wrap(uri), headers: _ua);
      if (res.statusCode != 401 && res.statusCode != 403) return res;
    }
    throw Exception('SoundCloud: доступ запрещён');
  }

  Track? _parse(Map j) {
    final transcodings = ((j['media'] as Map?)?['transcodings'] as List?) ?? [];
    if (transcodings.isEmpty) return null;
    final meta = (j['publisher_metadata'] as Map?) ?? {};
    final user = (j['user'] as Map?) ?? {};
    final created = j['release_date'] ?? j['created_at'];
    final title = (j['title'] as String?) ?? '';
    // SoundCloud заранее сообщает форматы: если открытых (progressive / обычный hls) нет — трек под DRM
    final drmOnly = !transcodings.whereType<Map>().any((t) {
      final protocol = '${(t['format'] as Map?)?['protocol']}';
      return protocol == 'progressive' || protocol == 'hls';
    });
    return Track(
      source: id,
      id: '${j['id']}',
      title: title,
      artist: (meta['artist'] as String?)?.isNotEmpty == true ? meta['artist'] : (user['username'] ?? ''),
      album: meta['album_title'],
      year: created is String && created.length >= 4 ? int.tryParse(created.substring(0, 4)) : null,
      genre: (j['genre'] as String?)?.isNotEmpty == true ? j['genre'] : null,
      coverUrl: ((j['artwork_url'] ?? user['avatar_url']) as String?)?.replaceAll('-large', '-t300x300'),
      duration: Duration(milliseconds: (j['duration'] as num?)?.toInt() ?? 0),
      explicit: meta['explicit'] == true || Track.explicitTags.hasMatch(title),
      // треки Go+ (только фрагмент) и треки только с защищёнными (DRM) потоками
      // считаем «неполными»: по нажатию на песню выберется версия с другой площадки
      previewOnly: j['policy'] == 'SNIP' || drmOnly,
      extra: {
        if (drmOnly) 'drm': true,
        'transcodings': transcodings,
        'auth': j['track_authorization'],
        'url': j['permalink_url'],
        if (user['id'] != null) 'artistId': '${user['id']}',
      },
    );
  }

  List<Track> _parseList(String body) =>
      ((jsonDecode(body)['collection'] as List?) ?? []).map((j) => _parse(j as Map)).whereType<Track>().toList();

  static String? _art(dynamic url) => (url as String?)?.replaceAll('-large', '-t300x300');

  AlbumRef _parseAlbum(Map p) {
    final user = (p['user'] as Map?) ?? {};
    final date = '${p['release_date'] ?? p['published_at'] ?? p['created_at'] ?? ''}';
    return AlbumRef(
      source: id,
      id: '${p['id']}',
      title: '${p['title'] ?? ''}',
      artist: '${user['username'] ?? ''}',
      coverUrl: _art(p['artwork_url'] ?? user['avatar_url']),
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      type: p['set_type'] as String?,
    );
  }

  ArtistRef _parseUser(Map u) => ArtistRef(
        source: id,
        id: '${u['id']}',
        name: '${u['username'] ?? ''}',
        imageUrl: _art(u['avatar_url']),
      );

  @override
  bool get hasCatalog => true;

  @override
  Future<List<AlbumRef>> searchAlbums(String query) async {
    final res = await _get('https://api-v2.soundcloud.com/search/albums', {'q': query, 'limit': '15'});
    if (res.statusCode != 200) return [];
    return ((jsonDecode(res.body)['collection'] as List?) ?? []).whereType<Map>().map(_parseAlbum).toList();
  }

  @override
  Future<List<ArtistRef>> searchArtists(String query) async {
    final res = await _get('https://api-v2.soundcloud.com/search/users', {'q': query, 'limit': '10'});
    if (res.statusCode != 200) return [];
    return ((jsonDecode(res.body)['collection'] as List?) ?? []).whereType<Map>().map(_parseUser).toList();
  }

  @override
  Future<AlbumInfo?> album(String albumId) async {
    final res = await _get('https://api-v2.soundcloud.com/playlists/$albumId');
    if (res.statusCode != 200) return null;
    final p = jsonDecode(res.body) as Map;
    final raw = ((p['tracks'] as List?) ?? []).whereType<Map>().toList();
    // SoundCloud отдаёт полные данные только первых треков, остальные — одними id
    final missing = raw.where((t) => t['media'] == null).map((t) => '${t['id']}').toList();
    final full = <String, Map>{};
    for (var i = 0; i < missing.length; i += 50) {
      final ids = missing.sublist(i, i + 50 > missing.length ? missing.length : i + 50).join(',');
      final r = await _get('https://api-v2.soundcloud.com/tracks', {'ids': ids});
      if (r.statusCode == 200) {
        for (final t in (jsonDecode(r.body) as List).whereType<Map>()) {
          full['${t['id']}'] = t;
        }
      }
    }
    final tracks = [
      for (final t in raw) _parse(t['media'] == null ? (full['${t['id']}'] ?? t) : t),
    ].whereType<Track>().toList();
    final user = p['user'] as Map?;
    return AlbumInfo(_parseAlbum(p), tracks, artist: user == null ? null : _parseUser(user));
  }

  @override
  Future<TrackPage> artistTracks(String artistId, {Object? cursor}) async {
    // SoundCloud сам даёт ссылку на следующую порцию (next_href)
    final http.Response res;
    if (cursor is String) {
      // параметры следующей порции (offset и др.) сохраняем, client_id подставит _get
      final next = Uri.parse(cursor);
      final params = Map.of(next.queryParameters)..remove('client_id');
      res = await _get(next.replace(query: '').toString().replaceFirst(RegExp(r'\?$'), ''), params);
    } else {
      res = await _get('https://api-v2.soundcloud.com/users/$artistId/tracks',
          {'limit': '50', 'linked_partitioning': '1'});
    }
    if (res.statusCode != 200) throw Exception('SoundCloud: HTTP ${res.statusCode}');
    final body = jsonDecode(res.body) as Map;
    return TrackPage(_parseList(res.body), body['next_href'] as String?);
  }

  @override
  Future<ArtistInfo?> artist(String artistId) async {
    final results = await Future.wait([
      _get('https://api-v2.soundcloud.com/users/$artistId'),
      _get('https://api-v2.soundcloud.com/users/$artistId/toptracks', {'limit': '20'}),
      _get('https://api-v2.soundcloud.com/users/$artistId/albums', {'limit': '50'}),
    ]);
    if (results[0].statusCode != 200) return null;
    return ArtistInfo(
      _parseUser(jsonDecode(results[0].body) as Map),
      topTracks: results[1].statusCode == 200 ? _parseList(results[1].body) : const [],
      albums: results[2].statusCode == 200
          ? ((jsonDecode(results[2].body)['collection'] as List?) ?? []).whereType<Map>().map(_parseAlbum).toList()
          : const [],
    );
  }

  @override
  Future<List<Track>> search(String query) async {
    final res = await _get('https://api-v2.soundcloud.com/search/tracks', {'q': query, 'limit': '25'});
    if (res.statusCode != 200) throw Exception('SoundCloud: HTTP ${res.statusCode}');
    return _parseList(res.body);
  }

  @override
  Future<List<Track>> similar(Track track) async {
    if (track.source != id) return [];
    final res = await _get('https://api-v2.soundcloud.com/tracks/${track.id}/related', {'limit': '25'});
    return res.statusCode == 200 ? _parseList(res.body) : [];
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async {
    try {
      return await _resolve(track);
    } on _NoPlayableStream {
      rethrow; // у трека только защищённые потоки — свежие данные не помогут
    } catch (_) {
      // данные из старого плейлиста могли устареть — берём свежие
      final res = await _get('https://api-v2.soundcloud.com/tracks/${track.id}');
      if (res.statusCode != 200) rethrow;
      final fresh = _parse(jsonDecode(res.body) as Map);
      if (fresh == null) rethrow;
      return _resolve(fresh);
    }
  }

  Future<StreamInfo> _resolve(Track track) async {
    // Только незашифрованные потоки: progressive mp3 → HLS mp3 → HLS aac/opus.
    // Варианты "encrypted-hls" защищены DRM и проиграны быть не могут.
    int? rank(Map t) {
      final f = (t['format'] as Map?) ?? {};
      final protocol = '${f['protocol']}';
      final mime = '${f['mime_type']}';
      if (protocol == 'progressive') return 0;
      if (protocol != 'hls') return null; // encrypted-hls и прочее
      if (mime.contains('mpeg')) return 1;
      return 2;
    }

    final all = (track.extra['transcodings'] as List).cast<Map>();
    final list = all.where((t) => rank(t) != null).toList()..sort((a, b) => rank(a)!.compareTo(rank(b)!));
    if (list.isEmpty) throw _NoPlayableStream(all.map(_describe).join(', '));

    // Некоторые варианты (часто старый progressive) уже отключены и отвечают 404 —
    // перебираем, пока какой-нибудь не ответит.
    final codes = <String>[];
    for (final chosen in list) {
      final res = await _get(chosen['url'] as String, {
        if (track.extra['auth'] != null) 'track_authorization': track.extra['auth'] as String,
      });
      if (res.statusCode == 200) {
        final url = (jsonDecode(res.body) as Map)['url'] as String?;
        if (url != null) {
          return StreamInfo(Uri.parse(url), hls: (chosen['format'] as Map?)?['protocol'] == 'hls');
        }
      }
      codes.add('${_describe(chosen)} → ${res.statusCode}');
    }
    final locked = all.where((t) => rank(t) == null).map(_describe);
    throw Exception('SoundCloud: поток недоступен [${codes.join('; ')}'
        '${locked.isEmpty ? '' : '; защищены: ${locked.join(', ')}'}]');
  }

  static String _describe(Map t) {
    final f = (t['format'] as Map?) ?? {};
    final mime = '${f['mime_type']}'.split(';').first.replaceFirst('audio/', '');
    return '${f['protocol']}/$mime';
  }

  static Uri? webUrl(Track t) => t.extra['url'] is String ? Uri.parse(t.extra['url'] as String) : null;
}

class _NoPlayableStream implements Exception {
  final String formats;
  const _NoPlayableStream(this.formats);
  @override
  String toString() => 'SoundCloud закрыл этот трек защитой (DRM) — он играет только в их приложении. '
      'Войди в Яндекс или Звук в настройках: если песня есть там, плеер возьмёт её оттуда';
}
