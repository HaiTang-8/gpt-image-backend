import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';

enum _ClearTarget { chat, image, all }

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();

  bool _testing = false;
  bool _saving = false;
  bool _resettingService = false;
  bool _showApiKey = false;
  String? _syncedBaseUrl;
  String? _syncedApiKey;
  _ClearTarget? _clearing;

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final colors = Theme.of(context).colorScheme;
    _syncServiceFields(app);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text('服务', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _baseUrlController,
          enabled: !_resettingService,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '后端地址',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _apiKeyController,
          enabled: !_resettingService,
          obscureText: !_showApiKey,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: '代理密钥',
            prefixIcon: const Icon(Icons.key_rounded),
            suffixIcon: IconButton(
              tooltip: _showApiKey ? '隐藏密钥' : '显示密钥',
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
              icon: Icon(
                _showApiKey
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _serviceActionDisabled(app) ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? '保存中' : '保存'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _serviceActionDisabled(app) ? null : _test,
                icon: _testing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check),
                label: Text(_testing ? '测试中' : '测试连接'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.settings_backup_restore_rounded,
            color: colors.primary,
          ),
          title: const Text('重置服务配置'),
          subtitle: const Text('恢复默认后端地址和密钥'),
          trailing: TextButton.icon(
            onPressed: _serviceResetDisabled(app) ? null : _confirmResetService,
            icon: _resettingService
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.restore_rounded),
            label: Text(_resettingService ? '重置中' : '重置'),
          ),
        ),
        if (app.lastError != null) ...[
          const SizedBox(height: 12),
          Text(app.lastError!, style: TextStyle(color: colors.error)),
        ],
        const SizedBox(height: 24),
        Text('数据', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _clearTile(
          app: app,
          colors: colors,
          target: _ClearTarget.chat,
          icon: Icons.chat_bubble_outline_rounded,
          title: '清除聊天记录',
          subtitle: '只清除文字聊天对话',
        ),
        const Divider(height: 1),
        _clearTile(
          app: app,
          colors: colors,
          target: _ClearTarget.image,
          icon: Icons.image_outlined,
          title: '清除图片记录',
          subtitle: '清除图片对话和生成记录',
        ),
        const Divider(height: 1),
        _clearTile(
          app: app,
          colors: colors,
          target: _ClearTarget.all,
          icon: Icons.delete_outline_rounded,
          title: '清除全部本地数据',
          subtitle: '清除聊天、图片对话和生成记录',
        ),
      ],
    );
  }

  Future<void> _confirmResetService() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('重置服务配置？'),
          content: const Text('后端地址和密钥会恢复为默认值。聊天和图片记录不会被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.restore_rounded),
              label: const Text('重置'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _resettingService = true);
    final reset = await context.read<AppState>().resetServiceConfig();
    if (!mounted) {
      return;
    }
    setState(() => _resettingService = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(reset ? '服务配置已重置' : '当前任务运行中，无法重置')));
  }

  Future<void> _save() async {
    await _saveServiceSettings();
  }

  Widget _clearTile({
    required AppState app,
    required ColorScheme colors,
    required _ClearTarget target,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final clearing = _clearing == target;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colors.error),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: colors.error),
        onPressed: _clearDisabled(app, target)
            ? null
            : () => _confirmClear(target),
        icon: clearing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.delete_forever_rounded),
        label: Text(clearing ? '清除中' : '清除'),
      ),
    );
  }

  Future<void> _test() async {
    final saved = await _saveServiceSettings(showSnackBar: false);
    if (!saved || !mounted) {
      return;
    }
    final app = context.read<AppState>();
    setState(() => _testing = true);
    final ok = await app.testConnection();
    if (!mounted) {
      return;
    }
    setState(() => _testing = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(ok ? '连接正常，密钥有效' : app.lastError ?? '连接失败')),
      );
  }

  Future<bool> _saveServiceSettings({bool showSnackBar = true}) async {
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写后端地址和代理密钥')));
      return false;
    }

    final app = context.read<AppState>();
    setState(() => _saving = true);
    try {
      app.config = app.config.copyWith(baseUrl: baseUrl);
      app.apiKey = apiKey;
      await app.saveSettings();
      _syncedBaseUrl = baseUrl;
      _syncedApiKey = apiKey;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return true;
    }
    if (showSnackBar) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('服务配置已保存')));
    }
    return true;
  }

  Future<void> _confirmClear(_ClearTarget target) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_dialogTitle(target)),
          content: Text(_dialogContent(target)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('清除'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _clearing = target);
    final app = context.read<AppState>();
    final cleared = switch (target) {
      _ClearTarget.chat => await app.clearChatData(),
      _ClearTarget.image => await app.clearImageData(),
      _ClearTarget.all => await app.clearUserData(),
    };
    if (!mounted) {
      return;
    }
    setState(() => _clearing = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cleared ? _successMessage(target) : _busyMessage(target)),
      ),
    );
  }

  bool _clearDisabled(AppState app, _ClearTarget target) {
    if (_clearing != null) {
      return true;
    }
    return switch (target) {
      _ClearTarget.chat => app.isSending,
      _ClearTarget.image => app.isWorkingOnImage,
      _ClearTarget.all => app.isBusy,
    };
  }

  bool _serviceResetDisabled(AppState app) {
    return _resettingService || _clearing != null || app.isBusy;
  }

  bool _serviceActionDisabled(AppState app) {
    return _saving ||
        _testing ||
        _resettingService ||
        _clearing != null ||
        app.isBusy;
  }

  void _syncServiceFields(AppState app) {
    final baseUrl = app.config.baseUrl;
    if (_syncedBaseUrl != baseUrl) {
      _baseUrlController.text = baseUrl;
      _syncedBaseUrl = baseUrl;
    }

    final apiKey = app.apiKey;
    if (_syncedApiKey != apiKey) {
      _apiKeyController.text = apiKey;
      _syncedApiKey = apiKey;
    }
  }

  String _dialogTitle(_ClearTarget target) {
    return switch (target) {
      _ClearTarget.chat => '清除聊天记录？',
      _ClearTarget.image => '清除图片记录？',
      _ClearTarget.all => '清除全部本地数据？',
    };
  }

  String _dialogContent(_ClearTarget target) {
    return switch (target) {
      _ClearTarget.chat => '文字聊天对话会被删除。后端地址和密钥会保留。',
      _ClearTarget.image => '图片对话和生成记录会被删除。后端地址和密钥会保留。',
      _ClearTarget.all => '聊天、图片对话和生成记录会被删除。后端地址和密钥会保留。',
    };
  }

  String _successMessage(_ClearTarget target) {
    return switch (target) {
      _ClearTarget.chat => '聊天记录已清除',
      _ClearTarget.image => '图片记录已清除',
      _ClearTarget.all => '本地数据已清除',
    };
  }

  String _busyMessage(_ClearTarget target) {
    return switch (target) {
      _ClearTarget.chat => '当前聊天运行中，无法清除',
      _ClearTarget.image => '当前图片任务运行中，无法清除',
      _ClearTarget.all => '当前任务运行中，无法清除',
    };
  }
}
