import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';

class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  ImageAspectRatio _aspectRatio = ImageAspectRatio.auto;
  XFile? _selectedImage;
  bool _isAutoScrollScheduled = false;

  @override
  void dispose() {
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final colors = Theme.of(context).colorScheme;
    final session = app.selectedImageSession;
    final images = app.selectedImages;

    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          _ImageSessionBar(session: session),
          if (app.lastError != null)
            _InlineError(message: app.lastError!, onClose: app.clearError),
          Expanded(
            child: session == null || images.isEmpty
                ? const _EmptyImageChat()
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
                        itemCount: images.length,
                        itemBuilder: (context, index) {
                          return _ImageTurn(image: images[index]);
                        },
                      );
                    },
                  ),
          ),
          _ImageComposerBar(
            controller: _promptController,
            aspectRatio: _aspectRatio,
            selectedImage: _selectedImage,
            continuesPreviousImage:
                _selectedImage == null && app.canContinueSelectedImageSession,
            isWorking: app.isWorkingOnImage,
            onAspectRatioChanged: (value) {
              setState(() => _aspectRatio = value);
            },
            onPickImage: _pickImage,
            onClearImage: () => setState(() => _selectedImage = null),
            onSubmit: () => _submit(app),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage() async {
    final image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() => _selectedImage = image);
    }
  }

  Future<void> _submit(AppState app) async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty || app.isWorkingOnImage) {
      return;
    }
    if (_selectedImage != null) {
      final image = _selectedImage!;
      _promptController.clear();
      final task = app.editImage(
        prompt: prompt,
        image: image,
        aspectRatio: _aspectRatio,
      );
      _jumpToLatestAfterLayout();
      await task;
      if (!mounted) {
        return;
      }
      if (app.lastError == null) {
        setState(() => _selectedImage = null);
      }
    } else {
      _promptController.clear();
      final task = app.generateImage(prompt, aspectRatio: _aspectRatio);
      _jumpToLatestAfterLayout();
      await task;
    }
    if (!mounted) {
      return;
    }
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
}

class _ImageSessionBar extends StatelessWidget {
  const _ImageSessionBar({required this.session});

  final ImageSession? session;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final colors = Theme.of(context).colorScheme;
    final currentSession = session;

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
                    value: currentSession?.id,
                    hint: Text(
                      '新图片对话',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    items: app.imageSessions
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
                        app.selectImageSession(value);
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '新图片对话',
              onPressed: app.newImageSession,
              icon: const Icon(Icons.add_rounded),
            ),
            if (currentSession != null)
              IconButton(
                tooltip: '删除当前图片对话',
                onPressed: app.isWorkingOnImage
                    ? null
                    : () => app.deleteImageSession(currentSession.id),
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

class _EmptyImageChat extends StatelessWidget {
  const _EmptyImageChat();

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
                Icons.image_outlined,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '想生成什么图片？',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '描述画面、风格和细节，图片会像回复一样出现在这里。',
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

class _ImageTurn extends StatelessWidget {
  const _ImageTurn({required this.image});

  final GeneratedImage image;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PromptBubble(text: image.prompt, sourceB64Json: image.sourceB64Json),
        switch (image.status) {
          GeneratedImageStatus.pending => const _GeneratingReply(),
          GeneratedImageStatus.completed => _ImageReply(image: image),
          GeneratedImageStatus.failed => _FailedImageReply(
            message: image.errorMessage ?? '图片生成失败',
          ),
        },
      ],
    );
  }
}

class _PromptBubble extends StatelessWidget {
  const _PromptBubble({required this.text, this.sourceB64Json});

  final String text;
  final String? sourceB64Json;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width > 900 ? 700.0 : width * 0.78;
    final sourceBytes = _decodeB64(sourceB64Json);

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
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (sourceBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  sourceBytes,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(text, style: TextStyle(color: colors.onPrimary, height: 1.38)),
          ],
        ),
      ),
    );
  }
}

Uint8List? _decodeB64(String? value) {
  final data = value?.trim();
  if (data == null || data.isEmpty) {
    return null;
  }
  try {
    return base64Decode(data);
  } catch (_) {
    return null;
  }
}

class _ImageReply extends StatelessWidget {
  const _ImageReply({required this.image});

  final GeneratedImage image;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width > 900 ? 520.0 : width * 0.78;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AssistantAvatar(icon: Icons.image_outlined),
          const SizedBox(width: 12),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colors.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: _ImagePreviewButton(image: image),
            ),
          ),
        ],
      ),
    );
  }
}

class _GeneratingReply extends StatelessWidget {
  const _GeneratingReply();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AssistantAvatar(icon: Icons.auto_awesome_rounded),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在生成图片...',
                  style: TextStyle(color: colors.onSurface, height: 1.42),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FailedImageReply extends StatelessWidget {
  const _FailedImageReply({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width > 900 ? 520.0 : width * 0.78;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AssistantAvatar(icon: Icons.error_outline_rounded),
          const SizedBox(width: 12),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer, height: 1.42),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 17, color: colors.onSurface),
    );
  }
}

class _ImageComposerBar extends StatelessWidget {
  const _ImageComposerBar({
    required this.controller,
    required this.aspectRatio,
    required this.selectedImage,
    required this.continuesPreviousImage,
    required this.isWorking,
    required this.onAspectRatioChanged,
    required this.onPickImage,
    required this.onClearImage,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final ImageAspectRatio aspectRatio;
  final XFile? selectedImage;
  final bool continuesPreviousImage;
  final bool isWorking;
  final ValueChanged<ImageAspectRatio> onAspectRatioChanged;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onSubmit;

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
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _AspectRatioSelector(
                        selected: aspectRatio,
                        onChanged: onAspectRatioChanged,
                      ),
                      _PickImageButton(
                        image: selectedImage,
                        onPressed: onPickImage,
                        onClear: selectedImage == null ? null : onClearImage,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: selectedImage == null
                                ? continuesPreviousImage
                                      ? '继续描述要调整哪里...'
                                      : '描述图片...'
                                : '描述要怎样修改或参考...',
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
                              value.text.trim().isNotEmpty && !isWorking;
                          return IconButton.filled(
                            tooltip: selectedImage == null
                                ? continuesPreviousImage
                                      ? '基于上一张继续生成'
                                      : '生成图片'
                                : '携图生成',
                            onPressed: canSend ? onSubmit : null,
                            icon: isWorking
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

class _PickImageButton extends StatelessWidget {
  const _PickImageButton({
    required this.image,
    required this.onPressed,
    required this.onClear,
  });

  final XFile? image;
  final VoidCallback onPressed;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final currentImage = image;
    if (currentImage == null) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('选择图片'),
        style: const ButtonStyle(
          visualDensity: VisualDensity(horizontal: -2, vertical: -2),
        ),
      );
    }

    final colors = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: FutureBuilder<Uint8List>(
                future: currentImage.readAsBytes(),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return Container(
                      width: 72,
                      height: 72,
                      color: colors.surfaceContainerHigh,
                      child: Icon(
                        Icons.image_outlined,
                        color: colors.onSurfaceVariant,
                      ),
                    );
                  }
                  return Image.memory(
                    bytes,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                  );
                },
              ),
            ),
          ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: IconButton.filledTonal(
            tooltip: '移除图片',
            onPressed: onClear,
            style: const ButtonStyle(
              fixedSize: WidgetStatePropertyAll(Size.square(26)),
              minimumSize: WidgetStatePropertyAll(Size.square(26)),
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.close_rounded, size: 16),
          ),
        ),
      ],
    );
  }
}

class _AspectRatioSelector extends StatelessWidget {
  const _AspectRatioSelector({required this.selected, required this.onChanged});

  final ImageAspectRatio selected;
  final ValueChanged<ImageAspectRatio> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<ImageAspectRatio>(
      initialValue: selected,
      onSelected: onChanged,
      itemBuilder: (context) {
        return ImageAspectRatio.values.map((value) {
          return PopupMenuItem(
            value: value,
            child: Row(
              children: [
                Icon(_iconFor(value)),
                const SizedBox(width: 12),
                Expanded(child: Text(value.label)),
                if (value == selected) const Icon(Icons.check),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconFor(selected), size: 18),
            const SizedBox(width: 8),
            Text(selected.label),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down_rounded),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ImageAspectRatio value) {
    return switch (value) {
      ImageAspectRatio.auto => Icons.crop_original_outlined,
      ImageAspectRatio.square => Icons.crop_square,
      ImageAspectRatio.portrait => Icons.crop_portrait,
      ImageAspectRatio.story => Icons.stay_current_portrait,
      ImageAspectRatio.landscape => Icons.crop_landscape,
      ImageAspectRatio.wide => Icons.smart_display_outlined,
    };
  }
}

class _ImagePreviewButton extends StatelessWidget {
  const _ImagePreviewButton({required this.image});

  final GeneratedImage image;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width * 0.78;
        return Semantics(
          button: true,
          label: '查看图片',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openImageViewer(context, image),
              child: Stack(
                children: [
                  _ImagePreview(
                    image: image,
                    fit: BoxFit.contain,
                    width: width,
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _ImageOverlayButton(
                      tooltip: '保存到相册',
                      icon: Icons.download_rounded,
                      onPressed: () {
                        _saveImageToGallery(context, image);
                      },
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _ImageOverlayButton(
                      tooltip: '查看图片',
                      icon: Icons.open_in_full_rounded,
                      onPressed: () => _openImageViewer(context, image),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ImageOverlayButton extends StatelessWidget {
  const _ImageOverlayButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.surface.withValues(alpha: 0.86),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 18, color: colors.onSurface),
          ),
        ),
      ),
    );
  }
}

class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.image});

  final GeneratedImage image;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
          title: const Text('图片预览'),
          actions: [
            IconButton(
              tooltip: '保存到相册',
              onPressed: () {
                _saveImageToGallery(context, image);
              },
              icon: const Icon(Icons.download_rounded),
            ),
          ],
        ),
        body: ColoredBox(
          color: colors.surface,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return InteractiveViewer(
                maxScale: 4,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: _ImagePreview(
                    image: image,
                    fit: BoxFit.contain,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({
    required this.image,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  final GeneratedImage image;
  final BoxFit fit;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final b64 = image.b64Json;
    if (b64 != null && b64.isNotEmpty) {
      late final Uint8List bytes;
      try {
        bytes = base64Decode(b64);
      } catch (_) {
        return SizedBox(
          width: width,
          height: height,
          child: const Center(child: Text('图片数据无法解析')),
        );
      }
      return Image.memory(bytes, width: width, height: height, fit: fit);
    }
    final url = image.url;
    if (url != null && url.isNotEmpty) {
      return Image.network(url, width: width, height: height, fit: fit);
    }
    return SizedBox(
      width: width,
      height: height,
      child: const Center(child: Text('接口未返回可显示图片')),
    );
  }
}

void _openImageViewer(BuildContext context, GeneratedImage image) {
  showDialog<void>(
    context: context,
    builder: (context) => _ImageViewerDialog(image: image),
  );
}

Future<void> _saveImageToGallery(
  BuildContext context,
  GeneratedImage image,
) async {
  try {
    final bytes = await _imageBytesFor(image);
    final hasAccess = await Gal.hasAccess();
    final canSave = hasAccess || await Gal.requestAccess();
    if (!canSave) {
      throw const _ImageSaveException('没有相册写入权限');
    }
    await Gal.putImageBytes(bytes, name: _imageName(image));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已保存到相册')));
  } on GalException catch (error) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('保存失败：${_galErrorMessage(error)}')),
      );
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
  }
}

Future<Uint8List> _imageBytesFor(GeneratedImage image) async {
  final b64 = image.b64Json;
  if (b64 != null && b64.isNotEmpty) {
    try {
      return base64Decode(b64);
    } on FormatException {
      throw const _ImageSaveException('图片数据无法解析');
    }
  }

  final url = image.url;
  if (url != null && url.isNotEmpty) {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.bodyBytes;
    }
    throw _ImageSaveException('图片下载失败（${response.statusCode}）');
  }

  throw const _ImageSaveException('接口未返回可下载图片');
}

String _imageName(GeneratedImage image) {
  return 'image-${image.id}';
}

String _galErrorMessage(GalException error) {
  return switch (error.type) {
    GalExceptionType.accessDenied => '没有相册写入权限',
    GalExceptionType.notEnoughSpace => '设备存储空间不足',
    GalExceptionType.notSupportedFormat => '图片格式不支持',
    GalExceptionType.unexpected => '相册保存失败',
  };
}

class _ImageSaveException implements Exception {
  const _ImageSaveException(this.message);

  final String message;

  @override
  String toString() => message;
}
