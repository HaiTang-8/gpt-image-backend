import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'models.dart';

class AppStorage {
  static const _configKey = 'config';
  static const _apiKeyKey = 'proxy_api_key';
  static const _settingsBoxName = 'settings';
  static const _sessionsBoxName = 'sessions';
  static const _imageSessionsBoxName = 'image_sessions';
  static const _imagesBoxName = 'images';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  late final Box _settingsBox;
  late final Box _sessionsBox;
  late final Box _imageSessionsBox;
  late final Box _imagesBox;

  Future<void> init() async {
    await Hive.initFlutter();
    _settingsBox = await Hive.openBox(_settingsBoxName);
    _sessionsBox = await Hive.openBox(_sessionsBoxName);
    _imageSessionsBox = await Hive.openBox(_imageSessionsBoxName);
    _imagesBox = await Hive.openBox(_imagesBoxName);
  }

  AppConfig loadConfig() {
    final raw = _settingsBox.get(_configKey);
    if (raw is Map) {
      return AppConfig.fromJson(Map<String, dynamic>.from(raw));
    }
    return const AppConfig();
  }

  Future<void> saveConfig(AppConfig config) {
    return _settingsBox.put(_configKey, config.toJson());
  }

  Future<String> loadApiKey() async {
    final saved = await _secureStorage.read(key: _apiKeyKey);
    if (saved == null || saved.trim().isEmpty) {
      return AppConfig.defaultApiKey;
    }
    return saved;
  }

  Future<void> saveApiKey(String value) {
    return _secureStorage.write(key: _apiKeyKey, value: value.trim());
  }

  List<ChatSession> loadSessions() {
    final sessions = _sessionsBox.values
        .whereType<Map>()
        .map((item) => ChatSession.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<void> saveSession(ChatSession session) {
    return _sessionsBox.put(session.id, session.toJson());
  }

  Future<void> deleteSession(String id) {
    return _sessionsBox.delete(id);
  }

  Future<void> clearChatData() {
    return _sessionsBox.clear();
  }

  Future<void> clearUserData() async {
    await Future.wait([clearChatData(), clearImageData()]);
  }

  List<ImageSession> loadImageSessions() {
    final sessions = _imageSessionsBox.values
        .whereType<Map>()
        .map((item) => ImageSession.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<void> saveImageSession(ImageSession session) {
    return _imageSessionsBox.put(session.id, session.toJson());
  }

  Future<void> deleteImageSession(String id) async {
    final imageKeys = _imagesBox.keys
        .where((key) {
          final raw = _imagesBox.get(key);
          return raw is Map && raw['sessionId'] == id;
        })
        .toList(growable: false);
    await _imagesBox.deleteAll(imageKeys);
    await _imageSessionsBox.delete(id);
  }

  Future<void> clearImageData() async {
    await Future.wait([_imageSessionsBox.clear(), _imagesBox.clear()]);
  }

  List<GeneratedImage> loadImages() {
    final images = _imagesBox.values
        .whereType<Map>()
        .map((item) => GeneratedImage.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    images.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return images;
  }

  Future<void> saveImage(GeneratedImage image) {
    return _imagesBox.put(image.id, image.toJson());
  }
}
