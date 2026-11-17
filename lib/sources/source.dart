import '../models/collection.dart';
import '../models/track.dart';

export '../models/collection.dart';

const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';

/// Ссылка на аудиопоток и его формат.
class StreamInfo {
  final Uri url;

  /// Поток HLS (плейлист .m3u8 из кусочков) — плееру надо сказать явно.
  final bool hls;
  const StreamInfo(this.url, {this.hls = false});
}

abstract class MusicSource {
  String get id;
  String get name;

  /// Источник готов к работе (например, указан токен).
  bool get isConfigured => true;

  Future<List<Track>> search(String query);

  /// Прямая ссылка на аудиопоток. Ссылки временные, поэтому получаем их прямо перед воспроизведением.
  /// Для видео-источников (YouTube) не используется.
  Future<StreamInfo> streamUrl(Track track);

  /// Похожие треки по версии самой площадки. Пусто, если площадка не умеет.
  Future<List<Track>> similar(Track track) async => [];

  // ---------- альбомы и исполнители (необязательно) ----------

  /// Площадка умеет отдавать альбомы и страницы исполнителей.
  bool get hasCatalog => false;

  /// Альбом по id (id лежит в track.albumId или AlbumRef.id).
  Future<AlbumInfo?> album(String albumId) async => null;

  /// Исполнитель по id: популярные треки и дискография.
  Future<ArtistInfo?> artist(String artistId) async => null;

  Future<List<AlbumRef>> searchAlbums(String query) async => [];
  Future<List<ArtistRef>> searchArtists(String query) async => [];
}
