import 'dart:convert';

import '../models/track.dart';
import '../sources/net.dart';
import 'lyrics.dart';

/// Genius: официальный API находит страницу песни; сам текст открывается на сайте Genius
/// (API текст не отдаёт, а вытаскивать его со страниц сайта правила Genius запрещают).
class GeniusService {
  String? token;
  GeniusService(this.token);

  final Map<String, Uri> _cache = {};

  static Uri searchUrl(Track t) =>
      Uri.https('genius.com', '/search', {'q': '${_artist(t)} ${LyricsService.cleanTitle(t.title)}'});

  static String _artist(Track t) =>
      t.artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first.trim();

  /// Ссылка на страницу песни на Genius; без токена или если не нашлось — поиск Genius.
  Future<Uri> pageFor(Track t) async {
    final hit = _cache[t.key];
    if (hit != null) return hit;
    var url = searchUrl(t);
    final tk = token;
    if (tk != null && tk.isNotEmpty) {
      try {
        final res = await Net.client.get(
          Net.wrap(Uri.https('api.genius.com', '/search', {'q': '${_artist(t)} ${LyricsService.cleanTitle(t.title)}'})),
          headers: {'Authorization': 'Bearer $tk'},
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final hits = ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['response']?['hits'] as List?) ?? [];
          final wanted = Track.normalize(LyricsService.cleanTitle(t.title));
          final artistKey = Track.normalize(_artist(t));
          Map? best;
          for (final h in hits.whereType<Map>()) {
            final r = h['result'] as Map?;
            if (r == null) continue;
            final sameArtist = Track.normalize('${(r['primary_artist'] as Map?)?['name'] ?? ''}') == artistKey;
            final sameTitle = Track.normalize('${r['title'] ?? ''}') == wanted;
            if (sameArtist && sameTitle) {
              best = r;
              break;
            }
            best ??= sameArtist ? r : null;
          }
          final u = best?['url'];
          if (u is String) url = Uri.parse(u);
        }
      } catch (_) {
        // сеть или токен — откроем поиск
      }
    }
    _cache[t.key] = url;
    return url;
  }
}
