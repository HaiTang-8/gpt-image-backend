import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'models.dart';

class ProxyApiClient {
  ProxyApiClient({
    required this.baseUrl,
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final http.Client _client;

  Uri _uri(String path) {
    final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$normalized$path');
  }

  Map<String, String> get _jsonHeaders => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };

  Future<bool> testConnection() async {
    final response = await _client
        .get(_uri('/healthz'))
        .timeout(const Duration(seconds: 8));
    return response.statusCode == 200 && response.body.trim() == 'ok';
  }

  Stream<String> streamChat({required List<ChatMessage> messages}) async* {
    final request = http.Request('POST', _uri('/v1/chat/completions'));
    request.headers.addAll({..._jsonHeaders, 'Accept': 'text/event-stream'});
    request.body = jsonEncode({
      'stream': true,
      'messages': messages
          .where((message) => message.content.trim().isNotEmpty)
          .map(
            (message) => {
              'role': message.role.wireName,
              'content': message.content,
            },
          )
          .toList(),
    });

    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw ProxyApiException(response.statusCode, body);
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) {
        continue;
      }
      final data = line.substring(5).trim();
      if (data == '[DONE]') {
        break;
      }
      if (data.isEmpty) {
        continue;
      }
      final payload = jsonDecode(data) as Map<String, dynamic>;
      final choices = payload['choices'] as List? ?? const [];
      if (choices.isEmpty || choices.first is! Map) {
        continue;
      }
      final choice = Map<String, dynamic>.from(choices.first as Map);
      final delta = choice['delta'];
      final message = choice['message'];
      final content = _contentFrom(delta) ?? _contentFrom(message);
      if (content != null && content.isNotEmpty) {
        yield content;
      }
    }
  }

  Future<GeneratedImage> generateImage({
    required String id,
    required String sessionId,
    required String prompt,
    required String? size,
  }) async {
    final body = <String, dynamic>{'prompt': prompt, 'n': 1};
    if (size != null) {
      body['size'] = size;
    }
    final response = await _client.post(
      _uri('/v1/images/generations'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    final data = _decodeImageResponse(response);
    return GeneratedImage(
      id: id,
      sessionId: sessionId,
      prompt: prompt,
      model: AppConfig.defaultImageModel,
      createdAt: DateTime.now(),
      url: data['url'] as String?,
      b64Json: data['b64_json'] as String?,
      revisedPrompt: data['revised_prompt'] as String?,
    );
  }

  Future<GeneratedImage> editImage({
    required String id,
    required String sessionId,
    required String prompt,
    required String? size,
    required XFile image,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/v1/images/edits'));
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['prompt'] = prompt;
    if (size != null) {
      request.fields['size'] = size;
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'image',
        await image.readAsBytes(),
        filename: image.name,
      ),
    );

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    final data = _decodeImageResponse(response);
    return GeneratedImage(
      id: id,
      sessionId: sessionId,
      prompt: prompt,
      model: AppConfig.defaultImageModel,
      createdAt: DateTime.now(),
      url: data['url'] as String?,
      b64Json: data['b64_json'] as String?,
      revisedPrompt: data['revised_prompt'] as String?,
      sourceFileName: image.name,
    );
  }

  Map<String, dynamic> _decodeImageResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProxyApiException(response.statusCode, response.body);
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final data = payload['data'] as List? ?? const [];
    if (data.isEmpty || data.first is! Map) {
      throw const FormatException('图片接口未返回 data[0]');
    }
    return Map<String, dynamic>.from(data.first as Map);
  }

  String? _contentFrom(Object? value) {
    if (value is! Map) {
      return null;
    }
    final content = value['content'];
    if (content is String) {
      return content;
    }
    return null;
  }
}

class ProxyApiException implements Exception {
  const ProxyApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return 'HTTP $statusCode';
    }
    return 'HTTP $statusCode: $trimmed';
  }
}
