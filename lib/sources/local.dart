import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'source.dart';

/// «Мои файлы»: музыка, которую пользователь сам добавил на устройство.
/// Файлы копируются в папку приложения, поэтому играют офлайн и не пропадают,
/// даже если оригинал удалили. В веб-версии недоступно.
class LocalSource extends MusicSource with ChangeNotifier {
  static const _exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav'];

  Directory? _dir;
  final List<_Entry> _entries = [];

  @override
  String get id => 'local';
  @override
  String get name => 'Мои файлы';
  @override
  bool get isConfigured => !kIsWeb && _entries.isNotEmpty;
  bool get supported => !kIsWeb;

  List<Track> get tracks => _entries.map(_toTrack).toList();

  File get _index => File('${_dir!.path}${Platform.pathSeparator}index.json');
  String _abs(String name) => '${_dir!.path}${Platform.pathSeparator}$name';

  Future<void> load() async {
    if (kIsWeb) return;
    final base = await getApplicationSupportDirectory();
    _dir = Directory('${base.path}${Platform.pathSeparator}music');
    await _dir!.create(recursive: true);
    try {
      if (await _index.exists()) {
        final list = jsonDecode(await _index.readAsString()) as List;
        _entries.addAll(list.map((j) => _Entry.fromJson(Map<String, dynamic>.from(j))));
        // файл могли удалить вручную
        _entries.removeWhere((e) => !File(_abs(e.file)).existsSync());
      }
    } catch (e) {
      debugPrint('Мои файлы: индекс повреждён: $e');
    }
  }

  Future<void> _save() async =>
      _index.writeAsString(jsonEncode(_entries.map((e) => e.toJson()).toList()), flush: true);

  Track _toTrack(_Entry e) => Track(
        source: id,
        id: e.id,
        title: e.title,
        artist: e.artist,
        album: e.album,
        year: e.year,
        genre: e.genre,
        coverUrl: e.cover == null ? null : Uri.file(_abs(e.cover!)).toString(),
        duration: e.ms == null ? null : Duration(milliseconds: e.ms!),
        explicit: Track.explicitTags.hasMatch('${e.title} ${e.file}'),
        // альбом и исполнитель у своих файлов — просто их названия из тегов
        extra: {if (e.album != null) 'albumId': e.album, 'artistId': e.artist},
      );

  // ---------- альбомы и исполнители по тегам ----------

  @override
  bool get hasCatalog => true;

  AlbumRef _albumRef(String album, List<_Entry> items) => AlbumRef(
        source: id,
        id: album,
        title: album,
        artist: items.first.artist,
        coverUrl: _toTrack(items.firstWhere((e) => e.cover != null, orElse: () => items.first)).coverUrl,
        year: items.first.year,
      );

  Map<String, List<_Entry>> get _byAlbum {
    final m = <String, List<_Entry>>{};
    for (final e in _entries.where((e) => e.album != null && e.album!.isNotEmpty)) {
      m.putIfAbsent(e.album!, () => []).add(e);
    }
    return m;
  }

  @override
  Future<AlbumInfo?> album(String albumId) async {
    final items = _byAlbum[albumId];
    if (items == null) return null;
    return AlbumInfo(_albumRef(albumId, items), items.map(_toTrack).toList(),
        artist: ArtistRef(source: id, id: items.first.artist, name: items.first.artist));
  }

  @override
  Future<ArtistInfo?> artist(String artistId) async {
    final items = _entries.where((e) => e.artist == artistId).toList();
    if (items.isEmpty) return null;
    final albums = _byAlbum.entries.where((a) => a.value.any((e) => e.artist == artistId));
    return ArtistInfo(
      ArtistRef(source: id, id: artistId, name: artistId, imageUrl: _toTrack(items.first).coverUrl),
      topTracks: items.map(_toTrack).toList(),
      albums: [for (final a in albums) _albumRef(a.key, a.value)],
    );
  }

  @override
  Future<List<AlbumRef>> searchAlbums(String query) async {
    final q = Track.normalize(query);
    if (q.isEmpty) return [];
    return [
      for (final a in _byAlbum.entries)
        if (Track.normalize('${a.key} ${a.value.first.artist}').contains(q)) _albumRef(a.key, a.value)
    ];
  }

  @override
  Future<List<ArtistRef>> searchArtists(String query) async {
    final q = Track.normalize(query);
    if (q.isEmpty) return [];
    final names = _entries.map((e) => e.artist).toSet().where((n) => Track.normalize(n).contains(q));
    return [for (final n in names) ArtistRef(source: id, id: n, name: n)];
  }

  /// Открыть системный выбор файлов и добавить выбранное. Возвращает число добавленных.
  Future<int> pickAndImport() async {
    if (kIsWeb) return 0;
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Выбери музыку',
      type: FileType.custom,
      allowedExtensions: _exts,
    );
    var added = 0;
    for (final f in files) {
      final src = f.path;
      if (src == null) continue;
      try {
        await _importOne(File(src), f.name);
        added++;
      } catch (e) {
        debugPrint('Не удалось добавить ${f.name}: $e');
      }
    }
    if (added > 0) {
      await _save();
      notifyListeners();
    }
    return added;
  }

  Future<void> _importOne(File src, String originalName) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final ext = originalName.contains('.') ? originalName.split('.').last.toLowerCase() : 'mp3';
    final fileName = '$id.$ext';
    await src.copy(_abs(fileName));

    // теги: исполнитель, название, альбом, год, жанр, обложка
    String? title, artist, album, genre, cover;
    int? year, ms;
    try {
      final m = readMetadata(File(_abs(fileName)), getImage: true);
      title = m.title?.trim();
      artist = m.artist?.trim();
      album = m.album?.trim();
      year = m.year?.year;
      ms = m.duration?.inMilliseconds;
      genre = m.genres.isNotEmpty ? m.genres.first : null;
      if (m.pictures.isNotEmpty) {
        final pic = m.pictures.first;
        cover = '$id.${pic.mimetype.contains('png') ? 'png' : 'jpg'}';
        await File(_abs(cover)).writeAsBytes(pic.bytes);
      }
    } catch (_) {
      // тегов нет или формат не читается — возьмём данные из имени файла
    }

    // «Исполнитель - Название.mp3», если в тегах пусто
    final base = originalName.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' ');
    final dash = RegExp(r'\s[-–—]\s').firstMatch(base);
    if (title == null || title.isEmpty) title = dash == null ? base : base.substring(dash.end).trim();
    if (artist == null || artist.isEmpty) artist = dash == null ? 'Неизвестный исполнитель' : base.substring(0, dash.start).trim();

    _entries.insert(
      0,
      _Entry(
          id: id, file: fileName, cover: cover, title: title, artist: artist, album: album, year: year, genre: genre, ms: ms),
    );
  }

  Future<void> remove(Track t) async {
    final e = _entries.where((e) => e.id == t.id).firstOrNull;
    if (e == null) return;
    _entries.remove(e);
    for (final name in [e.file, if (e.cover != null) e.cover!]) {
      try {
        await File(_abs(name)).delete();
      } catch (_) {}
    }
    await _save();
    notifyListeners();
  }

  @override
  Future<List<Track>> search(String query) async {
    final words = Track.normalize(query).split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];
    return _entries
        .where((e) {
          final hay = Track.normalize('${e.artist} ${e.title} ${e.album ?? ''}');
          return words.every(hay.contains);
        })
        .map(_toTrack)
        .toList();
  }

  @override
  Future<StreamInfo> streamUrl(Track track) async {
    final e = _entries.where((e) => e.id == track.id).firstOrNull;
    if (e == null) throw Exception('файл удалён из «Моих файлов»');
    return StreamInfo(Uri.file(_abs(e.file)));
  }
}

class _Entry {
  final String id, file, title, artist;
  final String? cover, album, genre;
  final int? year, ms;
  _Entry({
    required this.id,
    required this.file,
    required this.title,
    required this.artist,
    this.cover,
    this.album,
    this.genre,
    this.year,
    this.ms,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'file': file,
        'title': title,
        'artist': artist,
        if (cover != null) 'cover': cover,
        if (album != null) 'album': album,
        if (genre != null) 'genre': genre,
        if (year != null) 'year': year,
        if (ms != null) 'ms': ms,
      };

  factory _Entry.fromJson(Map<String, dynamic> j) => _Entry(
        id: j['id'],
        file: j['file'],
        title: j['title'],
        artist: j['artist'],
        cover: j['cover'],
        album: j['album'],
        genre: j['genre'],
        year: j['year'],
        ms: j['ms'],
      );
}
