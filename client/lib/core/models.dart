class AppConfig {
  const AppConfig({this.baseUrl = defaultBaseUrl});

  static const defaultBaseUrl = 'http://localhost:8080';
  static const defaultApiKey = 'replace-with-proxy-key';
  static const defaultChatModel = 'gpt-5.5';
  static const defaultImageModel = 'gpt-image-2';

  final String baseUrl;

  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;

  AppConfig copyWith({String? baseUrl}) {
    return AppConfig(baseUrl: baseUrl ?? this.baseUrl);
  }

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl};

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(baseUrl: json['baseUrl'] as String? ?? defaultBaseUrl);
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

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.failed = false,
  });

  final String id;
  final MessageRole role;
  final String content;
  final DateTime createdAt;
  final bool failed;

  ChatMessage copyWith({String? content, bool? failed}) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      failed: failed ?? this.failed,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.wireName,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'failed': failed,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.fromWireName(json['role'] as String? ?? 'user'),
      content: json['content'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
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
  final String? errorMessage;

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
      errorMessage: json['errorMessage'] as String?,
    );
  }
}
