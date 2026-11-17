import 'dart:convert';

import '../models/track.dart';
import 'net.dart';
import 'source.dart';

/// Audius — бесплатная площадка, куда артисты сами загружают музыку (без цензуры, полные треки).
/// Открытый API без ключа, поддерживает CORS — в браузере работает без прокси.
/// Документация: https://docs.audius.org/developers/api
class AudiusSource extends MusicSource {
  static const _app = 'music_player';
  String? _host;

  @override
  String get id => 'audius';
  @override
  String get name => 'Audius';

  /// Основной адрес сам отвечает на запросы API — без лишнего запроса списка узлов.
  static const _mainHost = 'https://api.audius.co';

  /// Audius децентрализован: если основной адрес не ответил, берём другой узел из списка.
  Future<String> _getHost({bool refresh = false}) async {
    if (!refresh) return _host ?? _mainHost;
    final res = await Net.client.get(Uri.https('api.audius.co', '/')).timeout(const Duration(seconds: 8));
    final hosts = ((jsonDecode(res.body) as Map)['data'] as List? ?? []).cast<String>()..remove(_host);
    if (hosts.isEmpty) throw Exception('Audius: нет доступных серверов');
    return _host = (hosts..shuffle()).first;
  }

  Future<dynamic> _get(String path, [Map<String, String> q = const {}]) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final host = await _getHost(refresh: attempt > 0);
        final res = await Net.client
            .get(Uri.parse('$host/v1$path').replace(queryParameters: {...q, 'app_name': _app}))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) return (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['data'];
      } catch (_) {
        // узел недоступен — пробуем другой
      }
    }
    throw Exception('Audius: сервер не отвечает');
  }

  Track _parse(Map j) {
    final art = j['artwork'] as Map? ?? {};
    final user = j['user'] as Map? ?? {};
    final title = j['title'] as String? ?? '';
    final tags = j['tags'] as String? ?? '';
    final release = (j['release_date'] as String?) ?? '';
    return Track(
      source: id,
      id: '${j['id']}',
      title: title,
      artist: user['name'] ?? user['handle'] ?? '',
      genre: (j['genre'] as String?)?.isNotEmpty == true ? j['genre'] : null,
      year: release.length >= 4 ? int.tryParse(release.substring(0, 4)) : null,
      coverUrl: art['480x480'] ?? art['150x150'],
      duration: Duration(seconds: (j['duration'] as num?)?.toInt() ?? 0),
      explicit: Track.explicitTags.hasMatch('$title $tags'),
      extra: {'permalink': j['permalink']},
    );
  }

  List<Track> _parseList(dynamic data) =>
      ((data as List?) ?? []).cast<Map>().where((j) => j['is_streamable'] != false).map(_parse).toList();

  @override
  Future<List<Track>> search(String query) async =>
      _parseList(await _get('/tracks/search', {'query': query, 'limit': '20'}));

  @override
  Future<StreamInfo> streamUrl(Track track) async {
    final host = await _getHost();
    // эндпоинт отвечает редиректом на mp3 — плеер проходит его сам
    return StreamInfo(Uri.parse('$host/v1/tracks/${track.id}/stream?app_name=$_app'));
  }

  /// Трендовые треки — для главной, когда истории ещё нет.
  Future<List<Track>> trending({String? genre}) async =>
      _parseList(await _get('/tracks/trending', {if (genre != null) 'genre': genre, 'time': 'week'}));
}
