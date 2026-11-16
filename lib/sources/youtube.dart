import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/track.dart';
import 'source.dart';

/// YouTube: поиск через официальный YouTube Data API (нужен бесплатный ключ),
/// воспроизведение — через официальный встроенный плеер YouTube.
class YouTubeSource extends MusicSource {
  String? apiKey;
  YouTubeSource(this.apiKey);

  @override
  String get id => 'youtube';
  @override
  String get name => 'YouTube';
  @override
  bool get isConfigured => apiKey != null && apiKey!.isNotEmpty;

  static Uri watchUrl(String videoId) => Uri.parse('https://www.youtube.com/watch?v=$videoId');

  Future<Map> _get(String path, Map<String, String> q) async {
    final res = await http.get(Uri.https('www.googleapis.com', '/youtube/v3/$path', {...q, 'key': apiKey!}));
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
    if (res.statusCode != 200) {
      final reason = ((body['error'] as Map?)?['errors'] as List?)?.firstOrNull?['reason'];
      if (reason == 'quotaExceeded') throw Exception('YouTube: дневной лимит поиска исчерпан');
      throw Exception('YouTube: ${(body['error'] as Map?)?['message'] ?? 'HTTP ${res.statusCode}'}');
    }
    return body;
  }

  @override
  Future<List<Track>> search(String query) async {
    final found = await _get('search', {
      'part': 'snippet',
      'type': 'video',
      'videoCategoryId': '10', // музыка
      'maxResults': '15',
      'q': query,
    });
    final items = (found['items'] as List? ?? []).cast<Map>();
    if (items.isEmpty) return [];
    final ids = items.map((i) => i['id']['videoId'] as String).toList();
    final details = await _get('videos', {'part': 'contentDetails', 'id': ids.join(',')});
    final durations = {
      for (final d in (details['items'] as List? ?? []).cast<Map>())
        d['id'] as String: _parseIsoDuration(d['contentDetails']['duration'] as String? ?? ''),
    };

    return items.map((i) {
      final s = i['snippet'] as Map;
      final videoId = i['id']['videoId'] as String;
      final rawTitle = _unescape(s['title'] as String? ?? '');
      var channel = _unescape(s['channelTitle'] as String? ?? '').replaceAll(RegExp(r'\s*-\s*Topic$|VEVO$'), '');
      // «Исполнитель - Песня» — самый частый формат названия музыкальных роликов
      var artist = channel, title = rawTitle;
      final dash = RegExp(r'\s[-–—]\s').firstMatch(rawTitle);
      if (dash != null) {
        artist = rawTitle.substring(0, dash.start).trim();
        title = rawTitle.substring(dash.end).trim();
      }
      final thumbs = s['thumbnails'] as Map? ?? {};
      return Track(
        source: id,
        id: videoId,
        title: title,
        artist: artist,
        coverUrl: ((thumbs['high'] ?? thumbs['medium'] ?? thumbs['default']) as Map?)?['url'],
        duration: durations[videoId],
        year: int.tryParse((s['publishedAt'] as String? ?? '').split('-').first),
        explicit: Track.explicitTags.hasMatch(rawTitle),
      );
    }).toList();
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async => StreamInfo(watchUrl(track.id));

  static Duration _parseIsoDuration(String iso) {
    final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(iso);
    if (m == null) return Duration.zero;
    int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
    return Duration(hours: g(1), minutes: g(2), seconds: g(3));
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}
