import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_image_client/core/api_client.dart';
import 'package:gpt_image_client/core/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('streamChat sends attachments as multimodal content', () async {
    late Map<String, dynamic> requestBody;
    final api = ProxyApiClient(
      baseUrl: 'http://proxy.test',
      apiKey: 'proxy-key',
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n'
          'data: [DONE]\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );

    final chunks = await api
        .streamChat(
          messages: [
            ChatMessage(
              id: 'm1',
              role: MessageRole.user,
              content: 'look',
              createdAt: DateTime.now(),
              attachments: const [
                ChatAttachment(
                  id: 'a1',
                  kind: ChatAttachmentKind.image,
                  name: 'photo.png',
                  mimeType: 'application/octet-stream',
                  data: 'aW1hZ2U=',
                ),
                ChatAttachment(
                  id: 'a2',
                  kind: ChatAttachmentKind.file,
                  name: 'brief.pdf',
                  mimeType: 'application/pdf',
                  data: 'cGRm',
                ),
              ],
            ),
          ],
        )
        .toList();

    final messages = requestBody['messages'] as List<dynamic>;
    final content =
        (messages.single as Map<String, dynamic>)['content'] as List<dynamic>;

    expect(chunks, ['ok']);
    expect(content[0], {'type': 'text', 'text': 'look'});
    expect(content[1], {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,aW1hZ2U='},
    });
    expect(content[2], {
      'type': 'file',
      'file': {
        'filename': 'brief.pdf',
        'file_data': 'data:application/pdf;base64,cGRm',
      },
    });
  });

  test('generateImage sends Responses image generation tool request', () async {
    late Map<String, dynamic> requestBody;
    final api = ProxyApiClient(
      baseUrl: 'http://proxy.test',
      apiKey: 'proxy-key',
      client: MockClient((incoming) async {
        requestBody = jsonDecode(incoming.body) as Map<String, dynamic>;
        return http.Response(
          '{"id":"resp_1","output":[{"id":"ig_1","type":"image_generation_call","result":"bmV3LWltYWdl","revised_prompt":"revised"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.generateImage(
      id: 'next',
      sessionId: 'is1',
      prompt: 'paint it',
      size: '1024x1024',
    );

    expect(requestBody['model'], AppConfig.defaultChatModel);
    expect(requestBody['input'], 'paint it');
    expect(requestBody['tools'], [
      {
        'type': 'image_generation',
        'model': AppConfig.defaultImageModel,
        'size': '1024x1024',
      },
    ]);
    expect(requestBody['tool_choice'], {'type': 'image_generation'});
    expect(result.b64Json, 'bmV3LWltYWdl');
    expect(result.revisedPrompt, 'revised');
    expect(result.responseId, 'resp_1');
    expect(result.imageGenerationCallId, 'ig_1');
  });

  test(
    'editGeneratedImage uses previous response context when available',
    () async {
      late Map<String, dynamic> requestBody;
      final api = ProxyApiClient(
        baseUrl: 'http://proxy.test',
        apiKey: 'proxy-key',
        client: MockClient((request) async {
          requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            '{"id":"resp_2","output":[{"id":"ig_2","type":"image_generation_call","result":"bmV4dA=="}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await api.editGeneratedImage(
        id: 'next',
        sessionId: 'is1',
        prompt: 'adjust it',
        size: null,
        image: GeneratedImage(
          id: 'base',
          sessionId: 'is1',
          prompt: 'base',
          model: AppConfig.defaultImageModel,
          createdAt: DateTime.now(),
          b64Json: 'aW1hZ2U=',
          responseId: 'resp_base',
        ),
      );

      expect(requestBody['previous_response_id'], 'resp_base');
      expect(requestBody['input'], 'adjust it');
      expect(result.b64Json, 'bmV4dA==');
      expect(result.responseId, 'resp_2');
    },
  );

  test(
    'editGeneratedImage downloads url image as Responses input fallback',
    () async {
      final calls = <String>[];
      late Map<String, dynamic> requestBody;
      final api = ProxyApiClient(
        baseUrl: 'http://proxy.test',
        apiKey: 'proxy-key',
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url}');
          if (request.method == 'GET') {
            return http.Response.bytes(
              utf8.encode('downloaded-image'),
              200,
              headers: {'content-type': 'image/jpeg'},
            );
          }
          requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            '{"id":"resp_3","output":[{"id":"ig_3","type":"image_generation_call","result":"bmV4dA=="}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await api.editGeneratedImage(
        id: 'next',
        sessionId: 'is1',
        prompt: 'adjust it',
        size: null,
        image: GeneratedImage(
          id: 'base',
          sessionId: 'is1',
          prompt: 'base',
          model: AppConfig.defaultImageModel,
          createdAt: DateTime.now(),
          url: 'http://cdn.test/base.jpg?token=1',
        ),
      );

      final input = requestBody['input'] as List<dynamic>;
      final content =
          (input.single as Map<String, dynamic>)['content'] as List<dynamic>;

      expect(calls, [
        'GET http://cdn.test/base.jpg?token=1',
        'POST http://proxy.test/v1/responses',
      ]);
      expect(content[0], {'type': 'input_text', 'text': 'adjust it'});
      expect(content[1], {
        'type': 'input_image',
        'image_url': 'data:image/jpeg;base64,ZG93bmxvYWRlZC1pbWFnZQ==',
      });
      expect(result.b64Json, 'bmV4dA==');
    },
  );
}
