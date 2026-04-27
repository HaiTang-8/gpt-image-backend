import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class AppVersionInfo {
  const AppVersionInfo({required this.versionName, required this.buildNumber});

  final String versionName;
  final int buildNumber;

  factory AppVersionInfo.fromJson(Map<dynamic, dynamic> json) {
    return AppVersionInfo(
      versionName: json['versionName'] as String? ?? '0.0.0',
      buildNumber: (json['buildNumber'] as num?)?.toInt() ?? 0,
    );
  }
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tagName,
    required this.versionName,
    required this.apkUrl,
    required this.releaseUrl,
    required this.releaseNotes,
    required this.publishedAt,
  });

  final String tagName;
  final String versionName;
  final String apkUrl;
  final String releaseUrl;
  final String releaseNotes;
  final DateTime? publishedAt;
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({required this.current, required this.latest});

  final AppVersionInfo current;
  final AppUpdateInfo? latest;
}

class AppUpdateService {
  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const _channel = MethodChannel('gpt_image_client/updater');
  static const _latestReleaseUrl =
      'https://api.github.com/repos/HaiTang-8/gpt-image-backend/releases/latest';

  final http.Client _client;

  bool get isAndroid => Platform.isAndroid;

  Future<AppUpdateCheckResult> checkForUpdate() async {
    if (!isAndroid) {
      return const AppUpdateCheckResult(
        current: AppVersionInfo(versionName: '0.0.0', buildNumber: 0),
        latest: null,
      );
    }
    final current = await currentVersion();

    final response = await _client
        .get(
          Uri.parse(_latestReleaseUrl),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'gpt-image-client',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw AppUpdateException('检查更新失败（HTTP ${response.statusCode}）');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AppUpdateException('更新信息格式异常');
    }
    final release = Map<String, dynamic>.from(decoded);
    final tagName = (release['tag_name'] as String?)?.trim() ?? '';
    final versionName = _versionFromTag(tagName);
    if (versionName.isEmpty ||
        !_isNewerVersion(versionName, current.versionName)) {
      return AppUpdateCheckResult(current: current, latest: null);
    }

    final apkUrl = _findApkUrl(release['assets']);
    if (apkUrl == null) {
      throw const AppUpdateException('最新 Release 未包含 app-release.apk');
    }

    return AppUpdateCheckResult(
      current: current,
      latest: AppUpdateInfo(
        tagName: tagName,
        versionName: versionName,
        apkUrl: apkUrl,
        releaseUrl: release['html_url'] as String? ?? '',
        releaseNotes: release['body'] as String? ?? '',
        publishedAt: DateTime.tryParse(
          release['published_at'] as String? ?? '',
        ),
      ),
    );
  }

  Future<AppVersionInfo> currentVersion() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('versionInfo');
    return AppVersionInfo.fromJson(raw ?? const {});
  }

  Future<String> downloadApk(
    AppUpdateInfo update, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(update.apkUrl));
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw AppUpdateException('下载 APK 失败（HTTP ${response.statusCode}）');
    }

    final dir = await Directory.systemTemp.createTemp('gpt_image_update_');
    final apkFile = File(
      '${dir.path}/gpt-image-client-${_safeName(update.tagName)}.apk',
    );
    final sink = apkFile.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, response.contentLength);
      }
    } finally {
      await sink.close();
    }
    return apkFile.path;
  }

  Future<bool> canRequestPackageInstalls() async {
    if (!isAndroid) {
      return false;
    }
    return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ??
        false;
  }

  Future<void> openInstallSettings() async {
    if (!isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('openInstallSettings');
  }

  Future<void> installApk(String apkPath) async {
    if (!isAndroid) {
      throw const AppUpdateException('当前平台不支持 APK 安装');
    }
    await _channel.invokeMethod<void>('installApk', {'path': apkPath});
  }

  static String? _findApkUrl(Object? assets) {
    if (assets is! List) {
      return null;
    }
    String? fallback;
    for (final asset in assets) {
      if (asset is! Map) {
        continue;
      }
      final item = Map<String, dynamic>.from(asset);
      final name = (item['name'] as String?)?.toLowerCase() ?? '';
      final url = item['browser_download_url'] as String?;
      if (url == null || !name.endsWith('.apk')) {
        continue;
      }
      if (name == 'app-release.apk') {
        return url;
      }
      fallback ??= url;
    }
    return fallback;
  }

  static String _versionFromTag(String tagName) {
    return tagName.trim().replaceFirst(RegExp(r'^[vV]'), '');
  }

  static bool _isNewerVersion(String latest, String current) {
    final latestParts = _versionParts(latest);
    final currentParts = _versionParts(current);
    final length = latestParts.length > currentParts.length
        ? latestParts.length
        : currentParts.length;
    for (var i = 0; i < length; i++) {
      final latestPart = i < latestParts.length ? latestParts[i] : 0;
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      if (latestPart != currentPart) {
        return latestPart > currentPart;
      }
    }
    return false;
  }

  static List<int> _versionParts(String version) {
    return version
        .split(RegExp(r'[.+-]'))
        .map(
          (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
        )
        .toList();
  }

  static String _safeName(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
