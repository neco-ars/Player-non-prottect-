/// Ключи приложения, вшитые при сборке — чтобы всё работало сразу после установки.
///
/// В исходном коде их нет: при сборке на GitHub они берутся из секретов репозитория,
/// при локальной сборке — из файла keys.json (он в .gitignore):
///   flutter build apk --dart-define-from-file=keys.json
///
/// Ключ из настроек приложения, если указан, важнее вшитого.
class AppKeys {
  static const youtube = String.fromEnvironment('YOUTUBE_KEY');
  static const genius = String.fromEnvironment('GENIUS_TOKEN');
  static const audiomackKey = String.fromEnvironment('AUDIOMACK_KEY');
  static const audiomackSecret = String.fromEnvironment('AUDIOMACK_SECRET');

  /// Свой ключ из настроек, иначе вшитый.
  static String? pick(String? user, String builtIn) =>
      user != null && user.trim().isNotEmpty ? user.trim() : (builtIn.isEmpty ? null : builtIn);
}
