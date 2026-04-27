import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'models.dart';
import 'storage.dart';

class AppState extends ChangeNotifier {
  AppState(this._storage);

  final AppStorage _storage;
  final Uuid _uuid = const Uuid();

  AppConfig config = const AppConfig();
  String apiKey = AppConfig.defaultApiKey;
  List<ChatSession> sessions = [];
  List<ImageSession> imageSessions = [];
  List<GeneratedImage> images = [];
  String? selectedSessionId;
  String? selectedImageSessionId;
  bool isSending = false;
  bool isWorkingOnImage = false;
  String? lastError;

  bool get isConfigured => config.hasBaseUrl && apiKey.trim().isNotEmpty;
  bool get isBusy => isSending || isWorkingOnImage;

  ChatSession? get selectedSession {
    for (final session in sessions) {
      if (session.id == selectedSessionId) {
        return session;
      }
    }
    return sessions.isEmpty ? null : sessions.first;
  }

  ImageSession? get selectedImageSession {
    for (final session in imageSessions) {
      if (session.id == selectedImageSessionId) {
        return session;
      }
    }
    return imageSessions.isEmpty ? null : imageSessions.first;
  }

  List<GeneratedImage> get selectedImages {
    final session = selectedImageSession;
    if (session == null) {
      return const [];
    }
    return images.where((image) => image.sessionId == session.id).toList();
  }

  Future<void> load() async {
    config = const AppConfig();
    apiKey = AppConfig.defaultApiKey;
    sessions = _storage.loadSessions();
    imageSessions = _storage.loadImageSessions();
    final staleImages = <GeneratedImage>[];
    images = _storage.loadImages().map((image) {
      if (image.status == GeneratedImageStatus.pending) {
        final failed = image.copyWith(
          status: GeneratedImageStatus.failed,
          errorMessage: '上次生成未完成',
        );
        staleImages.add(failed);
        return failed;
      }
      return image;
    }).toList();
    for (final image in staleImages) {
      await _storage.saveImage(image);
    }
    selectedSessionId = sessions.isEmpty ? null : sessions.first.id;
    selectedImageSessionId = imageSessions.isEmpty
        ? null
        : imageSessions.first.id;
    notifyListeners();
  }

  ProxyApiClient _api() {
    return ProxyApiClient(baseUrl: config.baseUrl, apiKey: apiKey);
  }

  Future<void> saveSettings() async {
    config = const AppConfig();
    apiKey = AppConfig.defaultApiKey;
    await _storage.saveConfig(config);
    await _storage.saveApiKey(apiKey);
    lastError = null;
    notifyListeners();
  }

  Future<bool> testConnection() async {
    lastError = null;
    notifyListeners();
    try {
      return await _api().testConnection();
    } catch (error) {
      lastError = error.toString();
      notifyListeners();
      return false;
    }
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  Future<void> newSession() async {
    final now = DateTime.now();
    final session = ChatSession(
      id: _uuid.v4(),
      title: '新会话',
      model: AppConfig.defaultChatModel,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );
    sessions = [session, ...sessions];
    selectedSessionId = session.id;
    await _storage.saveSession(session);
    notifyListeners();
  }

  void selectSession(String id) {
    selectedSessionId = id;
    notifyListeners();
  }

  Future<void> deleteSession(String id) async {
    sessions = sessions.where((session) => session.id != id).toList();
    if (selectedSessionId == id) {
      selectedSessionId = sessions.isEmpty ? null : sessions.first.id;
    }
    await _storage.deleteSession(id);
    notifyListeners();
  }

  Future<bool> clearUserData() async {
    if (isBusy) {
      return false;
    }
    await _storage.clearUserData();
    sessions = [];
    imageSessions = [];
    images = [];
    selectedSessionId = null;
    selectedImageSessionId = null;
    lastError = null;
    notifyListeners();
    return true;
  }

  Future<bool> clearChatData() async {
    if (isSending) {
      return false;
    }
    await _storage.clearChatData();
    sessions = [];
    selectedSessionId = null;
    lastError = null;
    notifyListeners();
    return true;
  }

  Future<bool> clearImageData() async {
    if (isWorkingOnImage) {
      return false;
    }
    await _storage.clearImageData();
    imageSessions = [];
    images = [];
    selectedImageSessionId = null;
    lastError = null;
    notifyListeners();
    return true;
  }

  Future<void> newImageSession() async {
    final now = DateTime.now();
    final session = ImageSession(
      id: _uuid.v4(),
      title: '新图片对话',
      createdAt: now,
      updatedAt: now,
    );
    imageSessions = [session, ...imageSessions];
    selectedImageSessionId = session.id;
    await _storage.saveImageSession(session);
    notifyListeners();
  }

  void selectImageSession(String id) {
    selectedImageSessionId = id;
    notifyListeners();
  }

  Future<void> deleteImageSession(String id) async {
    if (isWorkingOnImage) {
      return;
    }
    imageSessions = imageSessions.where((session) => session.id != id).toList();
    images = images.where((image) => image.sessionId != id).toList();
    if (selectedImageSessionId == id) {
      selectedImageSessionId = imageSessions.isEmpty
          ? null
          : imageSessions.first.id;
    }
    await _storage.deleteImageSession(id);
    notifyListeners();
  }

  Future<void> sendMessage(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || isSending) {
      return;
    }
    if (!isConfigured) {
      lastError = '请先完成服务配置';
      notifyListeners();
      return;
    }
    if (selectedSession == null) {
      await newSession();
    }

    isSending = true;
    lastError = null;
    final now = DateTime.now();
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: prompt,
      createdAt: now,
    );
    final assistantMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.assistant,
      content: '',
      createdAt: now,
    );
    var session = selectedSession!;
    session = session.copyWith(
      title: session.messages.isEmpty ? _titleFrom(prompt) : session.title,
      model: AppConfig.defaultChatModel,
      messages: [...session.messages, userMessage, assistantMessage],
      updatedAt: now,
    );
    _replaceSession(session);
    notifyListeners();

    try {
      await for (final chunk in _api().streamChat(messages: session.messages)) {
        final latest = selectedSession;
        if (latest == null) {
          continue;
        }
        final messages = latest.messages.map((message) {
          if (message.id == assistantMessage.id) {
            return message.copyWith(content: message.content + chunk);
          }
          return message;
        }).toList();
        session = latest.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        );
        _replaceSession(session);
        notifyListeners();
      }
    } catch (error) {
      lastError = error.toString();
      final latest = selectedSession;
      if (latest != null) {
        final messages = latest.messages.map((message) {
          if (message.id == assistantMessage.id) {
            final content = message.content.isEmpty
                ? '请求失败：$error'
                : '${message.content}\n\n请求失败：$error';
            return message.copyWith(content: content, failed: true);
          }
          return message;
        }).toList();
        session = latest.copyWith(
          messages: messages,
          updatedAt: DateTime.now(),
        );
        _replaceSession(session);
      }
    } finally {
      isSending = false;
      await _storage.saveSession(session);
      notifyListeners();
    }
  }

  Future<void> generateImage(
    String prompt, {
    required ImageAspectRatio aspectRatio,
  }) async {
    final value = prompt.trim();
    if (value.isEmpty || isWorkingOnImage) {
      return;
    }
    if (!isConfigured) {
      lastError = '请先完成服务配置';
      notifyListeners();
      return;
    }
    final now = DateTime.now();
    final imageSession = await _prepareImageSession(value, now);
    final id = _uuid.v4();
    final pending = GeneratedImage(
      id: id,
      sessionId: imageSession.id,
      prompt: value,
      model: AppConfig.defaultImageModel,
      createdAt: now,
      status: GeneratedImageStatus.pending,
    );
    images = [pending, ...images];
    isWorkingOnImage = true;
    lastError = null;
    notifyListeners();
    await _storage.saveImage(pending);
    try {
      final image = await _api().generateImage(
        id: id,
        sessionId: imageSession.id,
        prompt: value,
        size: aspectRatio.imageSize,
      );
      final completed = image.copyWith(
        createdAt: pending.createdAt,
        status: GeneratedImageStatus.completed,
      );
      _replaceImage(completed);
      await _storage.saveImage(completed);
    } catch (error) {
      final message = error.toString();
      lastError = message;
      final failed = pending.copyWith(
        status: GeneratedImageStatus.failed,
        errorMessage: message,
      );
      _replaceImage(failed);
      await _storage.saveImage(failed);
    } finally {
      isWorkingOnImage = false;
      notifyListeners();
    }
  }

  Future<void> editImage({
    required String prompt,
    required XFile image,
    required ImageAspectRatio aspectRatio,
  }) async {
    final value = prompt.trim();
    if (value.isEmpty || isWorkingOnImage) {
      return;
    }
    if (!isConfigured) {
      lastError = '请先完成服务配置';
      notifyListeners();
      return;
    }
    final now = DateTime.now();
    final imageSession = await _prepareImageSession(value, now);
    final id = _uuid.v4();
    final pending = GeneratedImage(
      id: id,
      sessionId: imageSession.id,
      prompt: value,
      model: AppConfig.defaultImageModel,
      createdAt: now,
      status: GeneratedImageStatus.pending,
      sourceFileName: image.name,
    );
    images = [pending, ...images];
    isWorkingOnImage = true;
    lastError = null;
    notifyListeners();
    await _storage.saveImage(pending);
    try {
      final result = await _api().editImage(
        id: id,
        sessionId: imageSession.id,
        prompt: value,
        size: aspectRatio.imageSize,
        image: image,
      );
      final completed = result.copyWith(
        createdAt: pending.createdAt,
        status: GeneratedImageStatus.completed,
      );
      _replaceImage(completed);
      await _storage.saveImage(completed);
    } catch (error) {
      final message = error.toString();
      lastError = message;
      final failed = pending.copyWith(
        status: GeneratedImageStatus.failed,
        errorMessage: message,
      );
      _replaceImage(failed);
      await _storage.saveImage(failed);
    } finally {
      isWorkingOnImage = false;
      notifyListeners();
    }
  }

  Future<ImageSession> _prepareImageSession(String prompt, DateTime now) async {
    if (selectedImageSession == null) {
      await newImageSession();
    }
    var session = selectedImageSession!;
    final hasImages = images.any((image) => image.sessionId == session.id);
    session = session.copyWith(
      title: hasImages ? session.title : _titleFrom(prompt),
      updatedAt: now,
    );
    _replaceImageSession(session);
    await _storage.saveImageSession(session);
    return session;
  }

  void _replaceImage(GeneratedImage updated) {
    images = [updated, ...images.where((image) => image.id != updated.id)]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void _replaceImageSession(ImageSession updated) {
    imageSessions = [
      updated,
      ...imageSessions.where((session) => session.id != updated.id),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    selectedImageSessionId = updated.id;
  }

  void _replaceSession(ChatSession updated) {
    sessions = [
      updated,
      ...sessions.where((session) => session.id != updated.id),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    selectedSessionId = updated.id;
  }

  String _titleFrom(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ');
    if (compact.length <= 24) {
      return compact;
    }
    return '${compact.substring(0, 24)}...';
  }
}
