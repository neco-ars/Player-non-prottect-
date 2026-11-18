import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/app_services.dart';
import '../sources/source.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'home_shell.dart';

/// Переходы к альбомам и исполнителям — из плеера, меню трека, поиска.

void openAlbumOf(BuildContext context, Track t) => HomeShell.push(
      context,
      AlbumPage(
        load: () => app.catalog.albumFor(t),
        title: t.album,
        notFound: () => 'Не нашёл альбом с «${t.title}».\n\n${app.catalog.lastReport}',
      ),
    );

void openArtistOf(BuildContext context, Track t) => HomeShell.push(
      context,
      ArtistPage(
        load: () => app.catalog.artistFor(t),
        title: t.artist,
        notFound: () => 'Не нашёл страницу «${t.artist}».\n\n${app.catalog.lastReport}',
      ),
    );

void openAlbum(BuildContext context, AlbumRef ref) => HomeShell.push(
      context,
      AlbumPage(load: () => app.catalog.album(ref), title: ref.title, preview: ref),
    );

void openArtist(BuildContext context, ArtistRef ref) => HomeShell.push(
      context,
      ArtistPage(load: () => app.catalog.artist(ref), title: ref.name),
    );
