import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const int _maxAttachmentBytes = 50 * 1024 * 1024;

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  final List<ChatAttachment> _attachments = [];
  bool _isAutoScrollScheduled = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final session = app.selectedSession;
    final colors = Theme.of(context).colorScheme;

    if (app.isSending && session != null && session.messages.isNotEmpty) {
      _jumpToLatestAfterLayout();
    }

    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          _SessionBar(session: session),
          if (app.lastError != null)
            _InlineError(message: app.lastError!, onClose: app.clearError),
          Expanded(
            child: session == null || session.messages.isEmpty
                ? const _EmptyChat()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final sidePadding = constraints.maxWidth > 920
                          ? (constraints.maxWidth - 860) / 2
                          : 16.0;
                      return ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: EdgeInsets.fromLTRB(
                          sidePadding,
                          18,
                          sidePadding,
                          24,
                        ),
                        itemCount: session.messages.length,
                        itemBuilder: (context, index) {
                          final message = session
                              .messages[session.messages.length - 1 - index];
                          return _MessageBubble(
                            message: message,
                            isSending: app.isSending,
                            onRetry: message.failed
                                ? () => _retry(app, message)
                                : null,
                          );
                        },
                      );
                    },
                  ),
          ),
          _ComposerBar(
            controller: _controller,
            attachments: _attachments,
            isSending: app.isSending,
            onPickImage: _pickImage,
            onPickFile: _pickFile,
            onRemoveAttachment: _removeAttachment,
            onSend: () => _send(app),
          ),
        ],
      ),
    );
  }

  Future<void> _send(AppState app) async {
    final text = _controller.text;
    _controller.clear();
    final attachments = List<ChatAttachment>.unmodifiable(_attachments);
    setState(_attachments.clear);
    await app.sendMessage(text, attachments: attachments);
    _jumpToLatestAfterLayout();
  }

  Future<void> _retry(AppState app, ChatMessage message) async {
    await app.retryMessage(message.id);
    _jumpToLatestAfterLayout();
  }

  void _jumpToLatestAfterLayout() {
    if (_isAutoScrollScheduled) {
      return;
    }
    _isAutoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isAutoScrollScheduled = false;
      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      _scrollController.jumpTo(0);
    });
  }

  Future<void> _pickImage() async {
    final image = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (image == null) {
      return;
    }
    final bytes = await image.readAsBytes();
    if (!mounted) {
      return;
    }
    _addAttachment(
      name: image.name,
      mimeType: _imageMimeTypeForPickedImage(image),
      bytes: bytes,
      kind: ChatAttachmentKind.image,
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) {
      return;
    }
    final mimeType = _mimeTypeForName(file.name);
    _addAttachment(
      name: file.name,
      mimeType: mimeType,
      bytes: bytes,
      kind: _isImageMime(mimeType)
          ? ChatAttachmentKind.image
          : ChatAttachmentKind.file,
    );
  }

  void _addAttachment({
    required String name,
    required String mimeType,
    required List<int> bytes,
    required ChatAttachmentKind kind,
  }) {
    if (bytes.length > _maxAttachmentBytes) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('附件不能超过 50MB')));
      return;
    }
    setState(() {
      _attachments.add(
        ChatAttachment(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          kind: kind,
          name: name,
          mimeType: mimeType,
          data: base64Encode(bytes),
        ),
      );
    });
  }

  void _removeAttachment(String id) {
    setState(() {
      _attachments.removeWhere((attachment) => attachment.id == id);
    });
  }
}

class _SessionBar extends StatelessWidget {
  const _SessionBar({required this.session});

  final ChatSession? session;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 42,
                padding: const EdgeInsets.only(left: 14, right: 8),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(21),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    borderRadius: BorderRadius.circular(12),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    isDense: true,
                    isExpanded: true,
                    value: session?.id,
                    hint: Text(
                      '新对话',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    items: app.sessions
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.id,
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        app.selectSession(value);
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '新对话',
              onPressed: app.newSession,
              icon: const Icon(Icons.add_rounded),
            ),
            if (session != null)
              IconButton(
                tooltip: '删除当前对话',
                onPressed: () => app.deleteSession(session!.id),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
              color: colors.onErrorContainer,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '今天想聊什么？',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '提问、写作、整理思路，直接输入就可以开始。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isSending,
    this.onRetry,
  });

  final ChatMessage message;
  final bool isSending;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width > 900 ? 700.0 : width * (isUser ? 0.78 : 0.88);

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.content.isNotEmpty)
                Text(
                  message.content,
                  style: TextStyle(color: colors.onPrimary, height: 1.38),
                ),
              if (message.attachments.isNotEmpty) ...[
                if (message.content.isNotEmpty) const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: message.attachments
                      .map(
                        (attachment) => _AttachmentPill(
                          attachment: attachment,
                          inverse: true,
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final foreground = message.failed
        ? colors.onErrorContainer
        : colors.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: message.failed
                  ? colors.errorContainer
                  : colors.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(
              message.failed
                  ? Icons.error_outline_rounded
                  : Icons.auto_awesome_rounded,
              size: 17,
              color: foreground,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: message.failed
                  ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
                  : const EdgeInsets.only(top: 2),
              decoration: message.failed
                  ? BoxDecoration(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(14),
                    )
                  : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GptMarkdown(
                    message.content.isEmpty ? '正在思考...' : message.content,
                    style: TextStyle(color: foreground, height: 1.42),
                  ),
                  if (message.failed && onRetry != null) ...[
                    const SizedBox(height: 10),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onErrorContainer,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: isSending
                          ? null
                          : () {
                              onRetry?.call();
                            },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.attachments,
    required this.isSending,
    required this.onPickImage,
    required this.onPickFile,
    required this.onRemoveAttachment,
    required this.onSend,
  });

  final TextEditingController controller;
  final List<ChatAttachment> attachments;
  final bool isSending;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;
  final ValueChanged<String> onRemoveAttachment;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (attachments.isNotEmpty) ...[
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: attachments
                            .map(
                              (attachment) => Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: _AttachmentPill(
                                  attachment: attachment,
                                  onRemove: () =>
                                      onRemoveAttachment(attachment.id),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      PopupMenuButton<_AttachmentAction>(
                        tooltip: '添加附件',
                        enabled: !isSending,
                        icon: const Icon(Icons.attach_file_rounded),
                        onSelected: (value) {
                          switch (value) {
                            case _AttachmentAction.image:
                              onPickImage();
                            case _AttachmentAction.file:
                              onPickFile();
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: _AttachmentAction.image,
                            child: Row(
                              children: [
                                Icon(Icons.image_outlined),
                                SizedBox(width: 12),
                                Text('图片'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: _AttachmentAction.file,
                            child: Row(
                              children: [
                                Icon(Icons.description_outlined),
                                SizedBox(width: 12),
                                Text('文件'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: '问点什么...',
                            hintStyle: TextStyle(
                              color: colors.onSurfaceVariant,
                            ),
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, child) {
                          final canSend =
                              (value.text.trim().isNotEmpty ||
                                  attachments.isNotEmpty) &&
                              !isSending;
                          return IconButton.filled(
                            tooltip: '发送',
                            onPressed: canSend ? onSend : null,
                            icon: isSending
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward_rounded),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AttachmentAction { image, file }

class _AttachmentPill extends StatelessWidget {
  const _AttachmentPill({
    required this.attachment,
    this.onRemove,
    this.inverse = false,
  });

  final ChatAttachment attachment;
  final VoidCallback? onRemove;
  final bool inverse;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = inverse ? colors.onPrimary : colors.onSurface;
    final background = inverse
        ? colors.onPrimary.withValues(alpha: 0.14)
        : colors.surfaceContainerHigh;

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: EdgeInsets.fromLTRB(8, 5, onRemove == null ? 8 : 4, 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_attachmentIcon(attachment.kind), size: 16, color: foreground),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground,
                height: 1.15,
              ),
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 15, color: foreground),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _attachmentIcon(ChatAttachmentKind kind) {
    return switch (kind) {
      ChatAttachmentKind.image => Icons.image_outlined,
      ChatAttachmentKind.file => Icons.description_outlined,
    };
  }
}

bool _isImageMime(String mimeType) {
  return mimeType.toLowerCase().startsWith('image/');
}

String _imageMimeTypeForPickedImage(XFile image) {
  final mimeType = image.mimeType?.trim();
  if (mimeType != null && _isImageMime(mimeType)) {
    return mimeType;
  }
  final inferred = _mimeTypeForName(image.name);
  return _isImageMime(inferred) ? inferred : 'image/png';
}

String _mimeTypeForName(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    _ => 'application/octet-stream',
  };
}
