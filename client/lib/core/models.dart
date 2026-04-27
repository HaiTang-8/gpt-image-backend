class AppConfig {
  const AppConfig({this.baseUrl = defaultBaseUrl});

  static const defaultBaseUrl = 'http://localhost:8083';
  static const defaultApiKey = 'replace-with-proxy-key';
  static const defaultChatModel = 'gpt-5.5';
  static const defaultImageModel = 'gpt-image-2';

  final String baseUrl;

  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;

  AppConfig copyWith({String? baseUrl}) {
    return AppConfig(baseUrl: baseUrl ?? this.baseUrl);
  }

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl};

  factory AppConfig.fromJson(
    Map<String, dynamic> json, {
    String fallbackBaseUrl = defaultBaseUrl,
  }) {
    return AppConfig(baseUrl: json['baseUrl'] as String? ?? fallbackBaseUrl);
  }
}

enum ImageAspectRatio {
  auto('自动', null),
  square('方形 1:1', '1024x1024'),
  portrait('竖版 3:4', '1024x1536'),
  story('故事 9:16', '1024x1536'),
  landscape('横屏 4:3', '1536x1024'),
  wide('宽屏 16:9', '1536x1024');

  const ImageAspectRatio(this.label, this.imageSize);

  final String label;
  final String? imageSize;
}

enum GeneratedImageStatus {
  pending,
  completed,
  failed;

  String get wireName => name;

  static GeneratedImageStatus fromWireName(String value) {
    return GeneratedImageStatus.values.firstWhere(
      (status) => status.wireName == value,
      orElse: () => GeneratedImageStatus.completed,
    );
  }
}

enum MessageRole {
  system,
  user,
  assistant;

  String get wireName => name;

  static MessageRole fromWireName(String value) {
    return MessageRole.values.firstWhere(
      (role) => role.wireName == value,
      orElse: () => MessageRole.user,
    );
  }
}

enum ChatAttachmentKind {
  image,
  file;

  String get wireName => name;

  static ChatAttachmentKind fromWireName(String value) {
    return ChatAttachmentKind.values.firstWhere(
      (kind) => kind.wireName == value,
      orElse: () => ChatAttachmentKind.file,
    );
  }
}

class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.mimeType,
    required this.data,
  });

  final String id;
  final ChatAttachmentKind kind;
  final String name;
  final String mimeType;
  final String data;

  String get dataUrl => 'data:$dataUrlMimeType;base64,$data';

  String get dataUrlMimeType {
    final value = mimeType.trim();
    if (kind != ChatAttachmentKind.image) {
      return value.isEmpty ? 'application/octet-stream' : value;
    }
    if (_isImageMimeType(value)) {
      return value;
    }
    return _imageMimeTypeForName(name) ?? 'image/png';
  }

  Map<String, dynamic> toChatContentPart() {
    return switch (kind) {
      ChatAttachmentKind.image => {
        'type': 'image_url',
        'image_url': {'url': dataUrl},
      },
      ChatAttachmentKind.file => {
        'type': 'file',
        'file': {'filename': name, 'file_data': dataUrl},
      },
    };
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.wireName,
    'name': name,
    'mimeType': mimeType,
    'data': data,
  };

  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    return ChatAttachment(
      id: json['id'] as String? ?? '',
      kind: ChatAttachmentKind.fromWireName(json['kind'] as String? ?? 'file'),
      name: json['name'] as String? ?? 'attachment',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      data: json['data'] as String? ?? '',
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.attachments = const [],
    this.failed = false,
  });

  final String id;
  final MessageRole role;
  final String content;
  final DateTime createdAt;
  final List<ChatAttachment> attachments;
  final bool failed;

  bool get hasPayload => content.trim().isNotEmpty || attachments.isNotEmpty;

  Object chatContentPayload() {
    if (attachments.isEmpty) {
      return content;
    }
    return [
      if (content.trim().isNotEmpty) {'type': 'text', 'text': content},
      ...attachments.map((attachment) => attachment.toChatContentPart()),
    ];
  }

  ChatMessage copyWith({
    String? content,
    List<ChatAttachment>? attachments,
    bool? failed,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      attachments: attachments ?? this.attachments,
      failed: failed ?? this.failed,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.wireName,
    'content': content,
    'attachments': attachments
        .map((attachment) => attachment.toJson())
        .toList(),
    'createdAt': createdAt.toIso8601String(),
    'failed': failed,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final attachments = (json['attachments'] as List? ?? [])
        .whereType<Map>()
        .map((item) => ChatAttachment.fromJson(Map<String, dynamic>.from(item)))
        .where((attachment) => attachment.data.isNotEmpty)
        .toList();
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.fromWireName(json['role'] as String? ?? 'user'),
      content: json['content'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      attachments: attachments,
      failed: json['failed'] as bool? ?? false,
    );
  }
}

class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.model,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String model;
  final List<ChatMessage> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  ChatSession copyWith({
    String? title,
    String? model,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
  }) {
    return ChatSession(
      id: id,
      title: title ?? this.title,
      model: model ?? this.model,
      messages: messages ?? this.messages,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    'messages': messages.map((message) => message.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final messages = (json['messages'] as List? ?? [])
        .whereType<Map>()
        .map((item) => ChatMessage.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String? ?? '新会话',
      model: json['model'] as String? ?? AppConfig.defaultChatModel,
      messages: messages,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class ImageSession {
  const ImageSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  ImageSession copyWith({String? title, DateTime? updatedAt}) {
    return ImageSession(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ImageSession.fromJson(Map<String, dynamic> json) {
    return ImageSession(
      id: json['id'] as String,
      title: json['title'] as String? ?? '新图片对话',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class GeneratedImage {
  const GeneratedImage({
    required this.id,
    required this.sessionId,
    required this.prompt,
    required this.model,
    required this.createdAt,
    this.status = GeneratedImageStatus.completed,
    this.url,
    this.b64Json,
    this.revisedPrompt,
    this.sourceFileName,
    this.sourceB64Json,
    this.sourceMimeType,
    this.responseId,
    this.imageGenerationCallId,
    this.errorMessage,
  });

  final String id;
  final String sessionId;
  final String prompt;
  final String model;
  final DateTime createdAt;
  final GeneratedImageStatus status;
  final String? url;
  final String? b64Json;
  final String? revisedPrompt;
  final String? sourceFileName;
  final String? sourceB64Json;
  final String? sourceMimeType;
  final String? responseId;
  final String? imageGenerationCallId;
  final String? errorMessage;

  bool get hasImagePayload {
    return (url?.trim().isNotEmpty ?? false) ||
        (b64Json?.trim().isNotEmpty ?? false);
  }

  GeneratedImage copyWith({
    String? sessionId,
    String? prompt,
    String? model,
    DateTime? createdAt,
    GeneratedImageStatus? status,
    String? url,
    String? b64Json,
    String? revisedPrompt,
    String? sourceFileName,
    String? sourceB64Json,
    String? sourceMimeType,
    String? responseId,
    String? imageGenerationCallId,
    String? errorMessage,
  }) {
    return GeneratedImage(
      id: id,
      sessionId: sessionId ?? this.sessionId,
      prompt: prompt ?? this.prompt,
      model: model ?? this.model,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      url: url ?? this.url,
      b64Json: b64Json ?? this.b64Json,
      revisedPrompt: revisedPrompt ?? this.revisedPrompt,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      sourceB64Json: sourceB64Json ?? this.sourceB64Json,
      sourceMimeType: sourceMimeType ?? this.sourceMimeType,
      responseId: responseId ?? this.responseId,
      imageGenerationCallId:
          imageGenerationCallId ?? this.imageGenerationCallId,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'prompt': prompt,
    'model': model,
    'createdAt': createdAt.toIso8601String(),
    'status': status.wireName,
    'url': url,
    'b64Json': b64Json,
    'revisedPrompt': revisedPrompt,
    'sourceFileName': sourceFileName,
    'sourceB64Json': sourceB64Json,
    'sourceMimeType': sourceMimeType,
    'responseId': responseId,
    'imageGenerationCallId': imageGenerationCallId,
    'errorMessage': errorMessage,
  };

  factory GeneratedImage.fromJson(Map<String, dynamic> json) {
    return GeneratedImage(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      model: json['model'] as String? ?? AppConfig.defaultImageModel,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      status: GeneratedImageStatus.fromWireName(
        json['status'] as String? ?? 'completed',
      ),
      url: json['url'] as String?,
      b64Json: json['b64Json'] as String?,
      revisedPrompt: json['revisedPrompt'] as String?,
      sourceFileName: json['sourceFileName'] as String?,
      sourceB64Json: json['sourceB64Json'] as String?,
      sourceMimeType: json['sourceMimeType'] as String?,
      responseId: json['responseId'] as String?,
      imageGenerationCallId: json['imageGenerationCallId'] as String?,
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

List<GeneratedImage> imageContextHistory(
  Iterable<GeneratedImage> images,
  String sessionId, {
  int limit = 4,
}) {
  final history =
      images
          .where(
            (image) =>
                image.sessionId == sessionId &&
                image.status == GeneratedImageStatus.completed,
          )
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  if (history.length <= limit) {
    return history;
  }
  return history.sublist(history.length - limit);
}

GeneratedImage? latestEditableImage(
  Iterable<GeneratedImage> images,
  String sessionId,
) {
  final candidates =
      images
          .where(
            (image) =>
                image.sessionId == sessionId &&
                image.status == GeneratedImageStatus.completed &&
                image.hasImagePayload,
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return candidates.isEmpty ? null : candidates.first;
}

String buildImageContextPrompt(
  String prompt,
  Iterable<GeneratedImage> history,
) {
  final current = _compactLine(prompt);
  final entries = history
      .map(_imageContextEntry)
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
  if (entries.isEmpty) {
    return current;
  }

  final buffer = StringBuffer()
    ..writeln(
      'Continue the same image conversation. If a source image is attached, use it as the visual source.',
    )
    ..writeln(
      'Continue the same image conversation and preserve subject, composition, style, and important details unless the current request changes them.',
    )
    ..writeln()
    ..writeln('Earlier requests in this image conversation:');
  for (final entry in entries) {
    buffer.writeln('- $entry');
  }
  buffer
    ..writeln()
    ..writeln('Current user request:')
    ..write(current);
  return buffer.toString();
}

String _imageContextEntry(GeneratedImage image) {
  final prompt = _compactLine(image.prompt);
  final revisedPrompt = _compactLine(image.revisedPrompt ?? '');
  if (prompt.isEmpty && revisedPrompt.isEmpty) {
    return '';
  }
  if (revisedPrompt.isEmpty || revisedPrompt == prompt) {
    return prompt;
  }
  if (prompt.isEmpty) {
    return 'Model interpretation: $revisedPrompt';
  }
  return '$prompt; model interpretation: $revisedPrompt';
}

String _compactLine(String value) {
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _isImageMimeType(String value) {
  return value.toLowerCase().startsWith('image/');
}

String? _imageMimeTypeForName(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    _ => null,
  };
}
