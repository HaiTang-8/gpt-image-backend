import 'dart:typed_data';

import 'package:gal/gal.dart';

const String imageSaveSuccessMessage = '已保存到相册';

Future<void> saveImageBytes(Uint8List bytes, {required String name}) async {
  try {
    final hasAccess = await Gal.hasAccess();
    final canSave = hasAccess || await Gal.requestAccess();
    if (!canSave) {
      throw const _ImageSaveException('没有相册写入权限');
    }
    await Gal.putImageBytes(bytes, name: name);
  } on GalException catch (error) {
    throw _ImageSaveException(_galErrorMessage(error));
  }
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
