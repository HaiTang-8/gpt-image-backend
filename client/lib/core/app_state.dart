import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'default_config.dart';
import 'models.dart';
import 'storage.dart';

class AppState extends ChangeNotifier {
  AppState(this._storage, this._defaultConfig);

  final AppStorage _storage;
  final DefaultClientConfig _defaultConfig;
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

  bool get canContinueSelectedImageSession {
    final session = selectedImageSession;
    return session != null && latestEditableImage(images, session.id) != null;
  }

  Future<void> load() async {
    config = _storage.loadConfig(fallback: _defaultConfig.appConfig);
    apiKey = await _storage.loadApiKey(fallback: _defaultConfig.apiKey);
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
    await _storage.saveConfig(config);
    await _storage.saveApiKey(apiKey);
    lastError = null;
    notifyListeners();
  }

  Future<bool> resetServiceConfig() async {
    if (isBusy) {
      return false;
    }
    await _storage.clearServiceConfig();
    config = _defaultConfig.appConfig;
    apiKey = _defaultConfig.apiKey;
    lastError = null;
    notifyListeners();
    return true;
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

  Future<void> sendMessage(
    String text, {
    List<ChatAttachment> attachments = const [],
  }) async {
    final prompt = text.trim();
    if ((prompt.isEmpty && attachments.isEmpty) || isSending) {
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
      attachments: attachments,
    );
    final assistantMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.assistant,
      content: '',
      createdAt: now,
    );
    var session = selectedSession!;
    final titleSource = prompt.isEmpty ? attachments.first.name : prompt;
    session = session.copyWith(
      title: session.messages.isEmpty ? _titleFrom(titleSource) : session.title,
      model: AppConfig.defaultChatModel,
      messages: [...session.messages, userMessage, assistantMessage],
      updatedAt: now,
    );
    _replaceSession(session);
    notifyListeners();

    await _streamAssistantMessage(
      initialSession: session,
      assistantMessageId: assistantMessage.id,
    );
  }

  Future<void> retryMessage(String messageId) async {
    if (isSending) {
      return;
    }
    if (!isConfigured) {
      lastError = '请先完成服务配置';
      notifyListeners();
      return;
    }
    final current = selectedSession;
    if (current == null) {
      return;
    }
    final failedIndex = current.messages.indexWhere(
      (message) =>
          message.id == messageId &&
          message.role == MessageRole.assistant &&
          message.failed,
    );
    if (failedIndex <= 0) {
      return;
    }

    var userIndex = -1;
    for (var index = failedIndex - 1; index >= 0; index--) {
      final message = current.messages[index];
      if (message.role == MessageRole.user && message.hasPayload) {
        userIndex = index;
        break;
      }
    }
    if (userIndex < 0) {
      return;
    }

    isSending = true;
    lastError = null;
    final now = DateTime.now();
    final assistantMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.assistant,
      content: '',
      createdAt: now,
    );
    final session = current.copyWith(
      messages: [...current.messages.take(userIndex + 1), assistantMessage],
      updatedAt: now,
    );
    _replaceSession(session);
    notifyListeners();

    await _streamAssistantMessage(
      initialSession: session,
      assistantMessageId: assistantMessage.id,
    );
  }

  Future<void> _streamAssistantMessage({
    required ChatSession initialSession,
    required String assistantMessageId,
  }) async {
    var session = initialSession;
    try {
      await for (final chunk in _api().streamChat(messages: session.messages)) {
        final latest = _sessionById(session.id);
        if (latest == null) {
          continue;
        }
        final messages = latest.messages.map((message) {
          if (message.id == assistantMessageId) {
            return message.copyWith(
              content: message.content + chunk,
              failed: false,
            );
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
      final latest = _sessionById(session.id);
      if (latest != null) {
        final messages = latest.messages.map((message) {
          if (message.id == assistantMessageId) {
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
    final history = imageContextHistory(images, imageSession.id);
    final baseImage = latestEditableImage(images, imageSession.id);
    final requestPrompt = baseImage == null
        ? buildImageContextPrompt(value, history)
        : value;
    final pending = GeneratedImage(
      id: id,
      sessionId: imageSession.id,
      prompt: value,
      model: AppConfig.defaultImageModel,
      createdAt: now,
      status: GeneratedImageStatus.pending,
      sourceFileName: baseImage == null ? null : '上一张图片',
    );
    images = [pending, ...images];
    isWorkingOnImage = true;
    lastError = null;
    notifyListeners();
    await _storage.saveImage(pending);
    try {
      final api = _api();
      final image = baseImage == null
          ? await api.generateImage(
              id: id,
              sessionId: imageSession.id,
              prompt: requestPrompt,
              size: aspectRatio.imageSize,
            )
          : await api.editGeneratedImage(
              id: id,
              sessionId: imageSession.id,
              prompt: requestPrompt,
              size: aspectRatio.imageSize,
              image: baseImage,
            );
      final completed = image.copyWith(
        prompt: pending.prompt,
        createdAt: pending.createdAt,
        status: GeneratedImageStatus.completed,
        sourceFileName: pending.sourceFileName,
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
    final history = imageContextHistory(images, imageSession.id);
    final requestPrompt = buildImageContextPrompt(value, history);
    final List<int> sourceBytes;
    try {
      sourceBytes = await image.readAsBytes();
    } catch (error) {
      lastError = '图片读取失败：$error';
      notifyListeners();
      return;
    }
    final sourceMimeType =
        image.mimeType ?? _imageMimeTypeForFileName(image.name);
    final pending = GeneratedImage(
      id: id,
      sessionId: imageSession.id,
      prompt: value,
      model: AppConfig.defaultImageModel,
      createdAt: now,
      status: GeneratedImageStatus.pending,
      sourceFileName: image.name,
      sourceB64Json: base64Encode(sourceBytes),
      sourceMimeType: sourceMimeType,
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
        prompt: requestPrompt,
        size: aspectRatio.imageSize,
        image: image,
      );
      final completed = result.copyWith(
        prompt: pending.prompt,
        createdAt: pending.createdAt,
        status: GeneratedImageStatus.completed,
        sourceFileName: pending.sourceFileName,
        sourceB64Json: pending.sourceB64Json,
        sourceMimeType: pending.sourceMimeType,
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

  Future<void> retryImage(
    String imageId, {
    required ImageAspectRatio aspectRatio,
  }) async {
    if (isWorkingOnImage) {
      return;
    }
    if (!isConfigured) {
      lastError = '请先完成服务配置';
      notifyListeners();
      return;
    }
    final failed = _imageById(imageId);
    if (failed == null || failed.status != GeneratedImageStatus.failed) {
      return;
    }
    final value = failed.prompt.trim();
    if (value.isEmpty) {
      return;
    }
    var session = _imageSessionById(failed.sessionId);
    if (session == null) {
      return;
    }

    final now = DateTime.now();
    session = session.copyWith(updatedAt: now);
    _replaceImageSession(session);
    await _storage.saveImageSession(session);

    final pending = GeneratedImage(
      id: failed.id,
      sessionId: failed.sessionId,
      prompt: value,
      model: AppConfig.defaultImageModel,
      createdAt: failed.createdAt,
      status: GeneratedImageStatus.pending,
      sourceFileName: failed.sourceFileName,
      sourceB64Json: failed.sourceB64Json,
      sourceMimeType: failed.sourceMimeType,
    );
    _replaceImage(pending);
    isWorkingOnImage = true;
    notifyListeners();
    await _storage.saveImage(pending);

    try {
      final api = _api();
      final history = _imageContextHistoryBefore(failed);
      final sourceData = failed.sourceB64Json?.trim();
      final GeneratedImage result;
      if (sourceData != null && sourceData.isNotEmpty) {
        final sourceFileName = failed.sourceFileName ?? 'source.png';
        final sourceImage = XFile.fromData(
          Uint8List.fromList(base64Decode(sourceData)),
          name: sourceFileName,
          mimeType:
              failed.sourceMimeType ??
              _imageMimeTypeForFileName(sourceFileName),
        );
        result = await api.editImage(
          id: pending.id,
          sessionId: pending.sessionId,
          prompt: buildImageContextPrompt(value, history),
          size: aspectRatio.imageSize,
          image: sourceImage,
        );
      } else {
        final baseImage = _latestEditableImageBefore(failed);
        result = baseImage == null
            ? await api.generateImage(
                id: pending.id,
                sessionId: pending.sessionId,
                prompt: buildImageContextPrompt(value, history),
                size: aspectRatio.imageSize,
              )
            : await api.editGeneratedImage(
                id: pending.id,
                sessionId: pending.sessionId,
                prompt: value,
                size: aspectRatio.imageSize,
                image: baseImage,
              );
      }
      final completed = result.copyWith(
        prompt: pending.prompt,
        createdAt: pending.createdAt,
        status: GeneratedImageStatus.completed,
        sourceFileName: pending.sourceFileName,
        sourceB64Json: pending.sourceB64Json,
        sourceMimeType: pending.sourceMimeType,
      );
      _replaceImage(completed);
      lastError = null;
      await _storage.saveImage(completed);
    } catch (error) {
      final message = error.toString();
      lastError = message;
      final failedRetry = pending.copyWith(
        status: GeneratedImageStatus.failed,
        errorMessage: message,
      );
      _replaceImage(failedRetry);
      await _storage.saveImage(failedRetry);
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

  ChatSession? _sessionById(String id) {
    for (final session in sessions) {
      if (session.id == id) {
        return session;
      }
    }
    return null;
  }

  ImageSession? _imageSessionById(String id) {
    for (final session in imageSessions) {
      if (session.id == id) {
        return session;
      }
    }
    return null;
  }

  GeneratedImage? _imageById(String id) {
    for (final image in images) {
      if (image.id == id) {
        return image;
      }
    }
    return null;
  }

  List<GeneratedImage> _imageContextHistoryBefore(GeneratedImage image) {
    return imageContextHistory(
      images.where(
        (candidate) =>
            candidate.id != image.id &&
            candidate.createdAt.isBefore(image.createdAt),
      ),
      image.sessionId,
    );
  }

  GeneratedImage? _latestEditableImageBefore(GeneratedImage image) {
    return latestEditableImage(
      images.where(
        (candidate) =>
            candidate.id != image.id &&
            candidate.createdAt.isBefore(image.createdAt),
      ),
      image.sessionId,
    );
  }

  String _titleFrom(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ');
    if (compact.length <= 24) {
      return compact;
    }
    return '${compact.substring(0, 24)}...';
  }
}

String _imageMimeTypeForFileName(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    _ => 'image/png',
  };
}
