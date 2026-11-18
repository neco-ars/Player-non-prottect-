import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../sources/net.dart';

/// Строка синхронного текста: когда её петь.
class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class Lyrics {
  /// Синхронный текст (строки с метками времени) — если есть.
  final List<LyricLine> synced;

  /// Обычный текст — если синхронного нет.
  final String? plain;
  final bool instrumental;
  const Lyrics({this.synced = const [], this.plain, this.instrumental = false});

  bool get isEmpty => synced.isEmpty && (plain == null || plain!.trim().isEmpty) && !instrumental;
}

/// Тексты песен из LRCLIB (lrclib.net) — открытая бесплатная база текстов, без ключа.
class LyricsService {
  static const _host = 'lrclib.net';
  final Map<String, Lyrics?> _cache = {};

  Future<Lyrics?> forTrack(Track t) async {
    if (_cache.containsKey(t.key)) return _cache[t.key];
    final title = cleanTitle(t.title);
    final artist = t.artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();
    Lyrics? result;

    // 1) точное совпадение по исполнителю, названию и длительности
    final exact = await _get('/api/get', {
      'artist_name': artist,
      'track_name': title,
      if (t.album != null && t.album!.isNotEmpty) 'album_name': t.album!,
      if ((t.duration?.inSeconds ?? 0) > 0) 'duration': '${t.duration!.inSeconds}',
    });
    if (exact is Map) result = _parse(exact);

    // 2) поиск — выбираем запись с ближайшей длительностью, предпочитая синхронные
    if (result == null || result.isEmpty) {
      final found = await _get('/api/search', {'track_name': title, 'artist_name': artist});
      if (found is List && found.isNotEmpty) {
        final secs = t.duration?.inSeconds ?? 0;
        final items = found.whereType<Map>().toList()
          ..sort((a, b) {
            int score(Map m) =>
                (secs == 0 ? 0 : ((m['duration'] as num? ?? 0) - secs).abs().round()) +
                (m['syncedLyrics'] == null ? 30 : 0);
            return score(a).compareTo(score(b));
          });
        result = _parse(items.first);
      }
    }
    _cache[t.key] = result;
    return result;
  }

  Future<dynamic> _get(String path, Map<String, String> q) async {
    try {
      final res = await Net.client
          .get(Uri.https(_host, path, q), headers: kIsWeb ? const {} : const {'User-Agent': 'MusicPlayer'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  static Lyrics _parse(Map m) => Lyrics(
        synced: parseLrc(m['syncedLyrics'] as String? ?? ''),
        plain: m['plainLyrics'] as String?,
        instrumental: m['instrumental'] == true,
      );

  /// «Nuke (feat. X) [Prod. Y] - Explicit» → «Nuke»: так база находит песню.
  static String cleanTitle(String s) => s
      .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
      .replaceAll(RegExp(r'\s[-–—]\s.*(explicit|remaster|version|edit).*$', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Разбор формата LRC: «[01:23.45] строка».
  static List<LyricLine> parseLrc(String lrc) {
    final re = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');
    final out = <LyricLine>[];
    for (final raw in const LineSplitter().convert(lrc)) {
      final stamps = re.allMatches(raw).toList();
      if (stamps.isEmpty) continue;
      final text = raw.substring(stamps.last.end).trim();
      for (final m in stamps) {
        final frac = m.group(3) ?? '0';
        final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
        out.add(LyricLine(
          Duration(minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!), milliseconds: ms),
          text,
        ));
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}
