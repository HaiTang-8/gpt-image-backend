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

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $apiKey'};

  Map<String, String> get _jsonHeaders => {
    ..._authHeaders,
    'Content-Type': 'application/json',
  };

  Future<bool> testConnection() async {
    final health = await _getWithTimeout(
      _uri('/healthz'),
      unreachableMessage: '后端不可达，请检查地址或服务状态',
    );
    if (health.statusCode != 200 || health.body.trim() != 'ok') {
      throw ProxyConnectionException(
        '后端不可达，请检查地址或服务状态（HTTP ${health.statusCode}）',
      );
    }

    final auth = await _getWithTimeout(
      _uri('/v1/auth/test'),
      headers: _authHeaders,
      unreachableMessage: '后端可达，但密钥校验失败',
    );
    if (auth.statusCode == 401) {
      throw const ProxyConnectionException('后端可达，但代理密钥无效');
    }
    if (auth.statusCode != 200 || auth.body.trim() != 'ok') {
      throw ProxyConnectionException('后端可达，但密钥校验接口异常（HTTP ${auth.statusCode}）');
    }
    return true;
  }

  Future<http.Response> _getWithTimeout(
    Uri uri, {
    Map<String, String>? headers,
    required String unreachableMessage,
  }) async {
    try {
      return await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw ProxyConnectionException('$unreachableMessage：请求超时');
    } catch (error) {
      throw ProxyConnectionException('$unreachableMessage：$error');
    }
  }

  Stream<String> streamChat({required List<ChatMessage> messages}) async* {
    final request = http.Request('POST', _uri('/v1/chat/completions'));
    request.headers.addAll({..._jsonHeaders, 'Accept': 'text/event-stream'});
    request.body = jsonEncode({
      'stream': true,
      'messages': messages
          .where((message) => message.hasPayload && !message.failed)
          .map(
            (message) => {
              'role': message.role.wireName,
              'content': message.chatContentPayload(),
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
    return _createImageResponse(
      id: id,
      sessionId: sessionId,
      prompt: prompt,
      size: size,
      action: 'generate',
    );
  }

  Future<GeneratedImage> editImage({
    required String id,
    required String sessionId,
    required String prompt,
    required String? size,
    required XFile image,
  }) async {
    return _createImageResponse(
      id: id,
      sessionId: sessionId,
      prompt: prompt,
      size: size,
      action: 'edit',
      inputImage: await _xFileImageInput(image),
      sourceFileName: image.name,
    );
  }

  Future<GeneratedImage> editGeneratedImage({
    required String id,
    required String sessionId,
    required String prompt,
    required String? size,
    required GeneratedImage image,
  }) async {
    return _createImageResponse(
      id: id,
      sessionId: sessionId,
      prompt: prompt,
      size: size,
      action: 'edit',
      inputImage: await _generatedImageInput(image),
      sourceFileName: _generatedImageFileName(image),
    );
  }

  Future<GeneratedImage> _createImageResponse({
    required String id,
    required String sessionId,
    required String prompt,
    required String? size,
    required String action,
    _ImageInput? inputImage,
    String? sourceFileName,
  }) async {
    final tool = <String, dynamic>{
      'type': 'image_generation',
      'model': AppConfig.defaultImageModel,
      'action': action,
    };
    if (size != null) {
      tool['size'] = size;
    }
    final body = <String, dynamic>{
      'model': AppConfig.defaultChatModel,
      'input': inputImage == null ? prompt : _imageInput(prompt, inputImage),
      'tools': [tool],
      'tool_choice': {'type': 'image_generation'},
    };

    final response = await _client.post(
      _uri('/v1/responses'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );

    final data = _decodeImageGenerationResponse(response);
    return GeneratedImage(
      id: id,
      sessionId: sessionId,
      prompt: prompt,
      model: AppConfig.defaultImageModel,
      createdAt: DateTime.now(),
      b64Json: data.result,
      revisedPrompt: data.revisedPrompt,
      sourceFileName: sourceFileName,
      responseId: data.responseId,
      imageGenerationCallId: data.callId,
    );
  }

  List<Map<String, dynamic>> _imageInput(String prompt, _ImageInput image) {
    return [
      {
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': prompt},
          {'type': 'input_image', 'image_url': image.dataUrl},
        ],
      },
    ];
  }

  Future<_ImageInput> _xFileImageInput(XFile image) async {
    return _ImageInput(
      dataUrl: _dataUrl(
        await image.readAsBytes(),
        image.mimeType ?? _mimeTypeForFileName(image.name),
      ),
    );
  }

  Future<_ImageInput> _generatedImageInput(GeneratedImage image) async {
    final b64 = image.b64Json;
    if (b64 != null && b64.trim().isNotEmpty) {
      return _ImageInput(dataUrl: 'data:image/png;base64,${b64.trim()}');
    }

    final url = image.url;
    if (url != null && url.trim().isNotEmpty) {
      final response = await _client.get(Uri.parse(url));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ProxyApiException(response.statusCode, response.body);
      }
      final fileName = _generatedImageFileName(
        image,
        contentType: response.headers['content-type'],
      );
      return _ImageInput(
        dataUrl: _dataUrl(
          response.bodyBytes,
          _contentType(response.headers['content-type']) ??
              _mimeTypeForFileName(fileName),
        ),
      );
    }

    throw const FormatException('上一张图片没有可编辑数据');
  }

  String _generatedImageFileName(GeneratedImage image, {String? contentType}) {
    final url = image.url;
    if (url != null && url.trim().isNotEmpty) {
      final uri = Uri.tryParse(url);
      final name = uri == null || uri.pathSegments.isEmpty
          ? ''
          : uri.pathSegments.last;
      if (_hasImageExtension(name)) {
        return name;
      }
    }
    return 'image-${image.id}${_extensionFor(contentType)}';
  }

  bool _hasImageExtension(String value) {
    final lower = value.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp');
  }

  String _extensionFor(String? contentType) {
    final type = _contentType(contentType);
    return switch (type) {
      'image/jpeg' => '.jpg',
      'image/webp' => '.webp',
      _ => '.png',
    };
  }

  String _dataUrl(List<int> bytes, String? mimeType) {
    return 'data:${_contentType(mimeType) ?? 'image/png'};base64,${base64Encode(bytes)}';
  }

  String? _contentType(String? value) {
    final type = value?.split(';').first.trim().toLowerCase();
    return type == null || type.isEmpty ? null : type;
  }

  String? _mimeTypeForFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    return null;
  }

  _ImageGenerationData _decodeImageGenerationResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProxyApiException(response.statusCode, response.body);
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final output = payload['output'] as List? ?? const [];
    for (final item in output) {
      if (item is! Map || item['type'] != 'image_generation_call') {
        continue;
      }
      final call = Map<String, dynamic>.from(item);
      final result = call['result'];
      if (result is String && result.trim().isNotEmpty) {
        return _ImageGenerationData(
          responseId: payload['id'] as String?,
          callId: call['id'] as String?,
          result: result,
          revisedPrompt: call['revised_prompt'] as String?,
        );
      }
    }
    throw const FormatException(
      'Responses API 未返回 image_generation_call.result',
    );
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

class _ImageInput {
  const _ImageInput({required this.dataUrl});

  final String dataUrl;
}

class _ImageGenerationData {
  const _ImageGenerationData({
    required this.responseId,
    required this.callId,
    required this.result,
    required this.revisedPrompt,
  });

  final String? responseId;
  final String? callId;
  final String result;
  final String? revisedPrompt;
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

class ProxyConnectionException implements Exception {
  const ProxyConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
