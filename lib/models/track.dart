/// Один трек из одного источника.
class Track {
  final String source; // id источника: 'yandex', 'soundcloud', 'youtube'
  final String id;
  final String title;
  final String artist;
  final String? album;
  final int? year;
  final String? genre;
  final String? coverUrl;
  final Duration? duration;
  final bool explicit;

  /// Источник отдаёт только фрагмент (например, треки SoundCloud Go+).
  final bool previewOnly;

  /// Данные, нужные источнику, чтобы потом получить ссылку на поток.
  final Map<String, dynamic> extra;

  const Track({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.year,
    this.genre,
    this.coverUrl,
    this.duration,
    this.explicit = false,
    this.previewOnly = false,
    this.extra = const {},
  });

  String get key => '$source:$id';

  /// id альбома и исполнителя на площадке трека (если площадка их дала).
  String? get albumId => extra['albumId']?.toString();
  String? get artistId => extra['artistId']?.toString();

  /// Видео YouTube играет через официальный плеер, а не через аудиоплеер.
  bool get isVideo => source == 'youtube';

  /// Ключ для объединения одинаковых песен с разных площадок.
  String get matchKey => '${normalize(artist)}|${normalize(title)}';

  /// Пометки в названии, по которым видно версию без цензуры.
  static final explicitTags = RegExp(r'\b(explicit|uncensored|dirty|nsfw|18\+)\b', caseSensitive: false);

  static String normalize(String s) {
    var t = s.toLowerCase();
    // убираем пометки вроде (feat. X), [Remastered], - Explicit
    t = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
    t = t.replaceAll(RegExp(r'\b(feat|ft|featuring)\.?\b.*'), ' ');
    t = t.replaceAll(
        RegExp(r'\b(explicit|clean|dirty|uncensored|remaster(ed)?|official|video|audio|lyrics?|music)\b'), ' ');
    t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
    return t.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'id': id,
        'title': title,
        'artist': artist,
        if (album != null) 'album': album,
        if (year != null) 'year': year,
        if (genre != null) 'genre': genre,
        if (coverUrl != null) 'cover': coverUrl,
        if (duration != null) 'ms': duration!.inMilliseconds,
        'explicit': explicit,
        'preview': previewOnly,
        'extra': extra,
      };

  factory Track.fromJson(Map<String, dynamic> j) => Track(
        source: j['source'],
        id: j['id'],
        title: j['title'] ?? '',
        artist: j['artist'] ?? '',
        album: j['album'],
        year: j['year'],
        genre: j['genre'],
        coverUrl: j['cover'],
        duration: j['ms'] == null ? null : Duration(milliseconds: j['ms']),
        explicit: j['explicit'] == true,
        previewOnly: j['preview'] == true,
        extra: Map<String, dynamic>.from(j['extra'] ?? const {}),
      );

  @override
  bool operator ==(Object other) => other is Track && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// Одна песня и все её найденные версии.
class TrackGroup {
  final List<Track> variants;
  TrackGroup(this.variants);

  /// Выбирать версию без цензуры, когда она есть (настройка «Предпочитать explicit»).
  static bool preferExplicit = true;
  static void preferExplicitDefault(bool v) => preferExplicit = v;

  /// Основная версия — та, что играет по нажатию на песню.
  /// Порядок: полная аудиоверсия → (explicit, если включено) → свой файл → остальное.
  Track get main {
    int score(Track t) =>
        (t.previewOnly ? 0 : 100) +
        (t.isVideo ? 0 : 50) +
        (preferExplicit && t.explicit ? 20 : 0) +
        (t.source == 'local' ? 10 : 0);
    var best = variants.first;
    for (final t in variants.skip(1)) {
      if (score(t) > score(best)) best = t;
    }
    return best;
  }

  bool get anyExplicit => variants.any((t) => t.explicit);
}
