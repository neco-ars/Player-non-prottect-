import 'track.dart';

/// Ссылка на альбом (сингл, EP) на площадке — для списков и поиска.
class AlbumRef {
  final String source;
  final String id;
  final String title;
  final String artist;
  final String? coverUrl;
  final int? year;
  final bool explicit;

  /// 'album', 'single', 'ep', 'compilation' — как отдаёт площадка (может быть пусто).
  final String? type;

  const AlbumRef({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.year,
    this.explicit = false,
    this.type,
  });

  String get typeLabel => switch (type?.toLowerCase()) {
        'single' => 'Сингл',
        'ep' => 'EP',
        'compilation' => 'Сборник',
        _ => 'Альбом',
      };
}

/// Ссылка на исполнителя на площадке.
class ArtistRef {
  final String source;
  final String id;
  final String name;
  final String? imageUrl;
  const ArtistRef({required this.source, required this.id, required this.name, this.imageUrl});
}

/// Альбом целиком: данные и треки по порядку.
class AlbumInfo {
  final AlbumRef ref;
  final List<Track> tracks;

  /// Исполнитель альбома (если площадка дала его id) — для перехода на страницу исполнителя.
  final ArtistRef? artist;
  const AlbumInfo(this.ref, this.tracks, {this.artist});
}

/// Страница исполнителя: популярные треки и дискография.
class ArtistInfo {
  final ArtistRef ref;
  final List<Track> topTracks;
  final List<AlbumRef> albums;
  const ArtistInfo(this.ref, {this.topTracks = const [], this.albums = const []});
}
