import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';

class DefaultClientConfig {
  const DefaultClientConfig({
    this.baseUrl = AppConfig.defaultBaseUrl,
    this.apiKey = AppConfig.defaultApiKey,
  });

  static const assetPath = 'assets/default_config.json';
  static const exampleAssetPath = 'assets/default_config.example.json';

  final String baseUrl;
  final String apiKey;

  AppConfig get appConfig => AppConfig(baseUrl: baseUrl);

  static Future<DefaultClientConfig> load({AssetBundle? bundle}) async {
    final effectiveBundle = bundle ?? rootBundle;
    for (final path in [assetPath, exampleAssetPath]) {
      final config = await _loadAsset(effectiveBundle, path);
      if (config != null) {
        return config;
      }
    }
    return const DefaultClientConfig();
  }

  factory DefaultClientConfig.fromJson(Map<String, dynamic> json) {
    final baseUrl = (json['baseUrl'] as String?)?.trim();
    final apiKey = (json['apiKey'] as String?)?.trim();
    return DefaultClientConfig(
      baseUrl: baseUrl == null || baseUrl.isEmpty
          ? AppConfig.defaultBaseUrl
          : baseUrl,
      apiKey: apiKey == null || apiKey.isEmpty
          ? AppConfig.defaultApiKey
          : apiKey,
    );
  }

  static Future<DefaultClientConfig?> _loadAsset(
    AssetBundle bundle,
    String path,
  ) async {
    try {
      final content = await bundle.loadString(path);
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        return null;
      }
      return DefaultClientConfig.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
