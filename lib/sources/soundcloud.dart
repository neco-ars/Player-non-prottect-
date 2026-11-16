import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  /// client_id берётся из JS сайта SoundCloud и иногда меняется,
  /// поэтому при ошибке 401/403 получаем его заново.
  Future<String> _getClientId({bool refresh = false}) async {
    if (_clientId != null && !refresh) return _clientId!;
    final page = await http.get(Net.wrap(Uri.https('soundcloud.com', '/')), headers: _ua);
    final idRe = RegExp(r'client_id\s*[:=]\s*"([0-9a-zA-Z]{32})"');
    // иногда client_id лежит прямо в HTML
    final inline = idRe.firstMatch(page.body);
    if (inline != null) return _clientId = inline.group(1)!;

    final scripts = RegExp(r'src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"')
        .allMatches(page.body)
        .map((m) => m.group(1)!)
        .toSet()
        .toList()
        .reversed; // client_id обычно в последних скриптах
    for (final src in scripts) {
      final js = await http.get(Net.wrap(Uri.parse(src)), headers: _ua);
      final m = idRe.firstMatch(js.body);
      if (m != null) return _clientId = m.group(1)!;
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
      final res = await http.get(Net.wrap(uri), headers: _ua);
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
      previewOnly: j['policy'] == 'SNIP', // треки Go+, доступен только фрагмент
      extra: {'transcodings': transcodings, 'auth': j['track_authorization'], 'url': j['permalink_url']},
    );
  }

  List<Track> _parseList(String body) =>
      ((jsonDecode(body)['collection'] as List?) ?? []).map((j) => _parse(j as Map)).whereType<Track>().toList();

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
  String toString() => 'SoundCloud отдаёт этот трек только в защищённом виде ($formats)';
}
