import 'package:flutter/foundation.dart';

/// Проверки платформы, безопасные для веба (dart:io Platform в браузере падает).
bool get isWeb => kIsWeb;
bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
bool get isMobile => isAndroid || isIOS;
bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);
