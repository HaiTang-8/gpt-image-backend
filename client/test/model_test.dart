import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_image_client/core/default_config.dart';
import 'package:gpt_image_client/core/models.dart';

void main() {
  test('AppConfig round trips through json', () {
    const config = AppConfig(baseUrl: AppConfig.defaultBaseUrl);

    final restored = AppConfig.fromJson(config.toJson());

    expect(restored.baseUrl, config.baseUrl);
  });

  test('AppConfig uses supplied fallback base url', () {
    final restored = AppConfig.fromJson(
      {},
      fallbackBaseUrl: 'http://asset-default.test',
    );

    expect(restored.baseUrl, 'http://asset-default.test');
  });

  test('DefaultClientConfig parses asset json shape', () {
    final config = DefaultClientConfig.fromJson({
      'baseUrl': ' http://example.test ',
      'apiKey': ' proxy-key ',
    });

    expect(config.baseUrl, 'http://example.test');
    expect(config.apiKey, 'proxy-key');
    expect(config.appConfig.baseUrl, config.baseUrl);
  });

  test('DefaultClientConfig falls back on missing values', () {
    final config = DefaultClientConfig.fromJson({});

    expect(config.baseUrl, AppConfig.defaultBaseUrl);
    expect(config.apiKey, AppConfig.defaultApiKey);
  });

  test('DefaultClientConfig loads real asset before example asset', () async {
    final config = await DefaultClientConfig.load(
      bundle: _StringAssetBundle({
        DefaultClientConfig.assetPath:
            '{"baseUrl":"http://real.test","apiKey":"real-key"}',
        DefaultClientConfig.exampleAssetPath:
            '{"baseUrl":"http://example.test","apiKey":"example-key"}',
      }),
    );

    expect(config.baseUrl, 'http://real.test');
    expect(config.apiKey, 'real-key');
  });

  test('DefaultClientConfig falls back to example asset', () async {
    final config = await DefaultClientConfig.load(
      bundle: _StringAssetBundle({
        DefaultClientConfig.exampleAssetPath:
            '{"baseUrl":"http://example.test","apiKey":"example-key"}',
      }),
    );

    expect(config.baseUrl, 'http://example.test');
    expect(config.apiKey, 'example-key');
  });

  test(
    'DefaultClientConfig falls back to constants when assets fail',
    () async {
      final config = await DefaultClientConfig.load(
        bundle: _StringAssetBundle({
          DefaultClientConfig.assetPath: 'not json',
          DefaultClientConfig.exampleAssetPath: '[]',
        }),
      );

      expect(config.baseUrl, AppConfig.defaultBaseUrl);
      expect(config.apiKey, AppConfig.defaultApiKey);
    },
  );

  test('ImageAspectRatio maps to supported image sizes', () {
    expect(ImageAspectRatio.auto.imageSize, isNull);
    expect(ImageAspectRatio.square.imageSize, '1024x1024');
    expect(ImageAspectRatio.portrait.imageSize, '1024x1536');
    expect(ImageAspectRatio.story.imageSize, '1024x1536');
    expect(ImageAspectRatio.landscape.imageSize, '1536x1024');
    expect(ImageAspectRatio.wide.imageSize, '1536x1024');
  });

  test('ChatSession restores nested messages', () {
    final now = DateTime.now();
    final session = ChatSession(
      id: 's1',
      title: 'hello',
      model: 'gpt-4o-mini',
      createdAt: now,
      updatedAt: now,
      messages: [
        ChatMessage(
          id: 'm1',
          role: MessageRole.user,
          content: 'hello',
          createdAt: now,
        ),
      ],
    );

    final restored = ChatSession.fromJson(session.toJson());

    expect(restored.messages, hasLength(1));
    expect(restored.messages.first.role, MessageRole.user);
    expect(restored.messages.first.content, 'hello');
  });

  test('ChatMessage round trips attachments through json', () {
    final now = DateTime.now();
    final message = ChatMessage(
      id: 'm1',
      role: MessageRole.user,
      content: 'read this',
      createdAt: now,
      attachments: const [
        ChatAttachment(
          id: 'a1',
          kind: ChatAttachmentKind.file,
          name: 'brief.pdf',
          mimeType: 'application/pdf',
          data: 'ZmFrZQ==',
        ),
      ],
    );

    final restored = ChatMessage.fromJson(message.toJson());

    expect(restored.attachments, hasLength(1));
    expect(restored.attachments.first.name, 'brief.pdf');
    expect(
      restored.attachments.first.dataUrl,
      startsWith('data:application/pdf'),
    );
  });

  test('ChatMessage builds multimodal chat payload', () {
    final now = DateTime.now();
    final message = ChatMessage(
      id: 'm1',
      role: MessageRole.user,
      content: 'describe it',
      createdAt: now,
      attachments: const [
        ChatAttachment(
          id: 'a1',
          kind: ChatAttachmentKind.image,
          name: 'photo.png',
          mimeType: 'image/png',
          data: 'aW1hZ2U=',
        ),
      ],
    );

    final content = message.chatContentPayload() as List<Object?>;

    expect(content.first, {'type': 'text', 'text': 'describe it'});
    expect(content.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,aW1hZ2U='},
    });
  });

  test('Chat image attachment fixes non image MIME in data URL', () {
    const attachment = ChatAttachment(
      id: 'a1',
      kind: ChatAttachmentKind.image,
      name: 'photo.png',
      mimeType: 'application/octet-stream',
      data: 'aW1hZ2U=',
    );

    expect(attachment.dataUrl, 'data:image/png;base64,aW1hZ2U=');
  });

  test('GeneratedImage restores status and error message', () {
    final now = DateTime.now();
    final image = GeneratedImage(
      id: 'i1',
      sessionId: 'is1',
      prompt: 'draw a house',
      model: AppConfig.defaultImageModel,
      createdAt: now,
      status: GeneratedImageStatus.failed,
      responseId: 'resp_1',
      imageGenerationCallId: 'ig_1',
      sourceB64Json: 'c291cmNl',
      sourceMimeType: 'image/png',
      errorMessage: 'request failed',
    );

    final restored = GeneratedImage.fromJson(image.toJson());

    expect(restored.status, GeneratedImageStatus.failed);
    expect(restored.sessionId, 'is1');
    expect(restored.responseId, 'resp_1');
    expect(restored.imageGenerationCallId, 'ig_1');
    expect(restored.sourceB64Json, 'c291cmNl');
    expect(restored.sourceMimeType, 'image/png');
    expect(restored.errorMessage, 'request failed');
  });

  test('GeneratedImage tolerates missing session id from old storage', () {
    final restored = GeneratedImage.fromJson({
      'id': 'i1',
      'sessionId': null,
      'prompt': 'draw a house',
      'model': AppConfig.defaultImageModel,
      'createdAt': DateTime.now().toIso8601String(),
    });

    expect(restored.sessionId, '');
  });

  test('image context history keeps recent completed session turns', () {
    final base = DateTime(2026);
    final images = [
      GeneratedImage(
        id: 'old',
        sessionId: 'is1',
        prompt: 'old',
        model: AppConfig.defaultImageModel,
        createdAt: base,
      ),
      GeneratedImage(
        id: 'recent',
        sessionId: 'is1',
        prompt: 'recent',
        model: AppConfig.defaultImageModel,
        createdAt: base.add(const Duration(minutes: 1)),
      ),
      GeneratedImage(
        id: 'failed',
        sessionId: 'is1',
        prompt: 'failed',
        model: AppConfig.defaultImageModel,
        createdAt: base.add(const Duration(minutes: 2)),
        status: GeneratedImageStatus.failed,
      ),
      GeneratedImage(
        id: 'other',
        sessionId: 'is2',
        prompt: 'other',
        model: AppConfig.defaultImageModel,
        createdAt: base.add(const Duration(minutes: 3)),
      ),
    ];

    final history = imageContextHistory(images, 'is1', limit: 1);

    expect(history.map((image) => image.id), ['recent']);
  });

  test('latestEditableImage ignores images without payload', () {
    final base = DateTime(2026);
    final image = latestEditableImage([
      GeneratedImage(
        id: 'empty',
        sessionId: 'is1',
        prompt: 'empty',
        model: AppConfig.defaultImageModel,
        createdAt: base.add(const Duration(minutes: 1)),
      ),
      GeneratedImage(
        id: 'ready',
        sessionId: 'is1',
        prompt: 'ready',
        model: AppConfig.defaultImageModel,
        createdAt: base,
        b64Json: 'aW1hZ2U=',
      ),
    ], 'is1');

    expect(image?.id, 'ready');
  });

  test('buildImageContextPrompt includes prior turns and current request', () {
    final prompt = buildImageContextPrompt('换成夜景', [
      GeneratedImage(
        id: 'i1',
        sessionId: 'is1',
        prompt: '生成一张街景',
        model: AppConfig.defaultImageModel,
        createdAt: DateTime(2026),
        revisedPrompt: 'A cinematic street scene',
      ),
    ]);

    expect(prompt, contains('Earlier requests'));
    expect(prompt, contains('生成一张街景'));
    expect(prompt, contains('A cinematic street scene'));
    expect(prompt, contains('Current user request'));
    expect(prompt, endsWith('换成夜景'));
  });

  test('ImageSession round trips through json', () {
    final now = DateTime.now();
    final session = ImageSession(
      id: 'is1',
      title: 'draw a house',
      createdAt: now,
      updatedAt: now,
    );

    final restored = ImageSession.fromJson(session.toJson());

    expect(restored.id, session.id);
    expect(restored.title, session.title);
  });
}

class _StringAssetBundle extends CachingAssetBundle {
  _StringAssetBundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) {
      throw StateError('Unable to load asset: $key');
    }
    final bytes = Uint8List.fromList(utf8.encode(value));
    return ByteData.sublistView(bytes);
  }
}
