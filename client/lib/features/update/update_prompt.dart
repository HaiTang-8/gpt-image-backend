import 'package:flutter/material.dart';

import '../../core/update_service.dart';

class UpdatePrompt {
  UpdatePrompt._();

  static final AppUpdateService _service = AppUpdateService();
  static bool _checking = false;

  static Future<void> check(BuildContext context, {bool silent = false}) async {
    if (_checking) {
      return;
    }
    _checking = true;
    try {
      if (!_service.isAndroid) {
        if (!silent && context.mounted) {
          _snack(context, '当前平台暂不支持自动更新');
        }
        return;
      }

      final result = await _service.checkForUpdate();
      if (!context.mounted) {
        return;
      }
      final latest = result.latest;
      if (latest == null) {
        if (!silent) {
          _snack(context, '已是最新版本');
        }
        return;
      }
      await _showUpdateDialog(context, latest);
    } catch (error) {
      if (!silent && context.mounted) {
        _snack(context, '检查更新失败：$error');
      }
    } finally {
      _checking = false;
    }
  }

  static Future<void> _showUpdateDialog(
    BuildContext context,
    AppUpdateInfo update,
  ) async {
    final install = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('发现新版本 ${update.versionName}'),
          content: SingleChildScrollView(
            child: Text(
              update.releaseNotes.trim().isEmpty
                  ? '可以下载并安装 GitHub Release 中的最新 Android APK。'
                  : update.releaseNotes.trim(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('稍后'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.system_update_alt_rounded),
              label: const Text('下载更新'),
            ),
          ],
        );
      },
    );
    if (install == true && context.mounted) {
      await _downloadAndInstall(context, update);
    }
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    AppUpdateInfo update,
  ) async {
    final result = await showDialog<_DownloadResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _UpdateDownloadDialog(service: _service, update: update),
    );
    if (!context.mounted || result == null) {
      return;
    }
    if (result.error != null) {
      _snack(context, '更新失败：${result.error}');
      return;
    }

    final canInstall = await _service.canRequestPackageInstalls();
    if (!context.mounted) {
      return;
    }
    if (!canInstall) {
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('需要安装权限'),
            content: const Text('请允许当前应用安装未知来源应用，然后返回重新点击下载更新。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('去设置'),
              ),
            ],
          );
        },
      );
      if (openSettings == true) {
        await _service.openInstallSettings();
      }
      return;
    }

    try {
      await _service.installApk(result.apkPath!);
      if (context.mounted) {
        _snack(context, '已打开系统安装程序');
      }
    } catch (error) {
      if (context.mounted) {
        _snack(context, '安装失败：$error');
      }
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.service, required this.update});

  final AppUpdateService service;
  final AppUpdateInfo update;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  double? _progress;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    try {
      final apkPath = await widget.service.downloadApk(
        widget.update,
        onProgress: (received, total) {
          if (!mounted || total == null || total <= 0) {
            return;
          }
          setState(() => _progress = received / total);
        },
      );
      if (mounted) {
        Navigator.of(context).pop(_DownloadResult(apkPath: apkPath));
      }
    } catch (error) {
      if (mounted) {
        Navigator.of(context).pop(_DownloadResult(error: error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = _progress == null
        ? null
        : '${(_progress!.clamp(0, 1) * 100).toStringAsFixed(0)}%';
    return AlertDialog(
      title: const Text('下载更新'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _progress),
          if (percent != null) ...[const SizedBox(height: 12), Text(percent)],
        ],
      ),
    );
  }
}

class _DownloadResult {
  const _DownloadResult({this.apkPath, this.error});

  final String? apkPath;
  final Object? error;
}
