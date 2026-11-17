import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/track.dart';
import 'net.dart';
import 'source.dart';

/// Яндекс Музыка. Работает от аккаунта пользователя: нужен его OAuth-токен,
/// полные треки доступны при активной подписке Плюс.
class YandexSource extends MusicSource {
  String? token;
  YandexSource(this.token);

  static const _api = 'api.music.yandex.net';

  /// Страница входа. После входа токен окажется в адресной строке после "access_token=".
  static final authUrl = Uri.parse(
      'https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d');

  @override
  String get id => 'yandex';
  @override
  String get name => 'Яндекс Музыка';
  @override
  bool get isConfigured => token != null && token!.isNotEmpty && !Net.proxyMissing;

  Map<String, String> get _headers => {
        'Authorization': 'OAuth $token',
        'X-Yandex-Music-Client': 'YandexMusicAndroid/24023621',
        if (!kIsWeb) 'User-Agent': 'Yandex-Music-API', // в браузере задать нельзя
      };

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final res = await Net.client.get(Net.wrap(Uri.https(_api, path, q)), headers: _headers);
    if (res.statusCode == 401) throw Exception('Яндекс: токен недействителен');
    if (res.statusCode != 200) throw Exception('Яндекс: HTTP ${res.statusCode}');
    return jsonDecode(utf8.decode(res.bodyBytes))['result'];
  }

  Track _parse(Map j) {
    final albums = (j['albums'] as List?) ?? [];
    final album = albums.isNotEmpty ? albums.first as Map : const {};
    final cover = j['coverUri'] as String? ?? album['coverUri'] as String?;
    return Track(
      source: id,
      id: '${j['id']}',
      title: [j['title'], j['version']].where((s) => s != null && '$s'.isNotEmpty).join(' '),
      artist: ((j['artists'] as List?) ?? []).map((a) => a['name']).join(', '),
      album: album['title'],
      year: album['year'],
      genre: album['genre'],
      coverUrl: cover == null ? null : 'https://${cover.replaceAll('%%', '400x400')}',
      duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
      explicit: j['contentWarning'] == 'explicit',
      extra: {
        if (album['id'] != null) 'albumId': '${album['id']}',
        if (((j['artists'] as List?) ?? []).isNotEmpty) 'artistId': '${(j['artists'] as List).first['id']}',
      },
    );
  }

  List<Track> _parseList(List? list) =>
      (list ?? []).cast<Map>().where((j) => j['available'] != false).map(_parse).toList();

  static String? _cover(String? uri, [int size = 400]) =>
      uri == null || uri.isEmpty ? null : 'https://${uri.replaceAll('%%', '${size}x$size')}';

  AlbumRef _parseAlbum(Map a) => AlbumRef(
        source: id,
        id: '${a['id']}',
        title: [a['title'], a['version']].where((s) => s != null && '$s'.isNotEmpty).join(' '),
        artist: ((a['artists'] as List?) ?? []).map((x) => x['name']).join(', '),
        coverUrl: _cover(a['coverUri'] as String?),
        year: a['year'] as int?,
        explicit: a['contentWarning'] == 'explicit',
        type: a['type'] as String?,
      );

  ArtistRef _parseArtist(Map a) => ArtistRef(
        source: id,
        id: '${a['id']}',
        name: '${a['name'] ?? ''}',
        imageUrl: _cover((a['cover'] as Map?)?['uri'] as String?),
      );

  @override
  bool get hasCatalog => true;

  @override
  Future<List<AlbumRef>> searchAlbums(String query) async {
    final r = await _get('/search', {'text': query, 'type': 'album', 'page': '0'});
    final list = (((r as Map?)?['albums'] as Map?)?['results'] as List?) ?? [];
    return list.whereType<Map>().map(_parseAlbum).toList();
  }

  @override
  Future<List<ArtistRef>> searchArtists(String query) async {
    final r = await _get('/search', {'text': query, 'type': 'artist', 'page': '0'});
    final list = (((r as Map?)?['artists'] as Map?)?['results'] as List?) ?? [];
    return list.whereType<Map>().map(_parseArtist).toList();
  }

  @override
  Future<AlbumInfo?> album(String albumId) async {
    final r = await _get('/albums/$albumId/with-tracks') as Map?;
    if (r == null) return null;
    // треки альбома разбиты на «тома» (диски)
    final volumes = (r['volumes'] as List?) ?? [];
    final tracks = [for (final v in volumes) ..._parseList(v as List?)];
    final artists = (r['artists'] as List?) ?? [];
    return AlbumInfo(_parseAlbum(r), tracks,
        artist: artists.isEmpty ? null : _parseArtist(artists.first as Map));
  }

  @override
  Future<TrackPage> artistTracks(String artistId, {Object? cursor}) async {
    const size = 50;
    final page = cursor is int ? cursor : 0;
    final r = await _get('/artists/$artistId/tracks', {'page': '$page', 'page-size': '$size'}) as Map?;
    final tracks = _parseList(r?['tracks'] as List?);
    final total = ((r?['pager'] as Map?)?['total'] as num?)?.toInt() ?? 0;
    return TrackPage(tracks, (page + 1) * size < total && tracks.isNotEmpty ? page + 1 : null);
  }

  @override
  Future<ArtistInfo?> artist(String artistId) async {
    final r = await _get('/artists/$artistId/brief-info') as Map?;
    if (r == null || r['artist'] == null) return null;
    final albums = ((r['albums'] as List?) ?? []).whereType<Map>().map(_parseAlbum).toList()
      ..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0));
    return ArtistInfo(
      _parseArtist(r['artist'] as Map),
      topTracks: _parseList(r['popularTracks'] as List?),
      albums: albums,
    );
  }

  @override
  Future<List<Track>> search(String query) async {
    final r = await _get('/search', {'text': query, 'type': 'track', 'page': '0', 'nocorrect': 'false'});
    return _parseList(((r as Map?)?['tracks'] as Map?)?['results']);
  }

  @override
  Future<List<Track>> similar(Track track) async {
    if (track.source != id) return [];
    final r = await _get('/tracks/${track.id}/similar');
    return _parseList((r as Map?)?['similarTracks']);
  }

  /// «Моя волна» — персональный поток рекомендаций Яндекса.
  Future<List<Track>> myWave() async {
    final r = await _get('/rotor/station/user:onyourwave/tracks', {'settings2': 'true'});
    final seq = ((r as Map?)?['sequence'] as List?) ?? [];
    return _parseList(seq.map((s) => s['track']).whereType<Map>().toList());
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async {
    final variants = ((await _get('/tracks/${track.id}/download-info')) as List? ?? []).cast<Map>()
      ..sort((a, b) {
        // mp3 с максимальным битрейтом; полные треки раньше превью
        final pa = a['preview'] == true ? 1 : 0, pb = b['preview'] == true ? 1 : 0;
        if (pa != pb) return pa - pb;
        if (a['codec'] != b['codec']) return a['codec'] == 'mp3' ? -1 : 1;
        return (b['bitrateInKbps'] as num).compareTo(a['bitrateInKbps'] as num);
      });
    if (variants.isEmpty) throw Exception('Яндекс: трек недоступен');
    final dl = await Net.client.get(Net.wrap(Uri.parse(variants.first['downloadInfoUrl'] as String)), headers: _headers);
    final doc = XmlDocument.parse(dl.body);
    String v(String name) => doc.findAllElements(name).first.innerText;
    final host = v('host'), path = v('path'), ts = v('ts'), s = v('s');
    final sign = md5.convert(utf8.encode('XGRlBW9FXlekgbPrRHuSiA${path.substring(1)}$s')).toString();
    return StreamInfo(Uri.parse('https://$host/get-mp3/$sign/$ts$path'));
  }
}
