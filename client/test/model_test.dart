import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_image_client/core/models.dart';

void main() {
  test('AppConfig round trips through json', () {
    const config = AppConfig(baseUrl: AppConfig.defaultBaseUrl);

    final restored = AppConfig.fromJson(config.toJson());

    expect(restored.baseUrl, config.baseUrl);
  });

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

  test('GeneratedImage restores status and error message', () {
    final now = DateTime.now();
    final image = GeneratedImage(
      id: 'i1',
      sessionId: 'is1',
      prompt: 'draw a house',
      model: AppConfig.defaultImageModel,
      createdAt: now,
      status: GeneratedImageStatus.failed,
      errorMessage: 'request failed',
    );

    final restored = GeneratedImage.fromJson(image.toJson());

    expect(restored.status, GeneratedImageStatus.failed);
    expect(restored.sessionId, 'is1');
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
