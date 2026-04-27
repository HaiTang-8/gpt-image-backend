import 'dart:typed_data';

import 'image_saver_mobile.dart'
    if (dart.library.html) 'image_saver_web.dart'
    as implementation;

String get imageSaveSuccessMessage => implementation.imageSaveSuccessMessage;

Future<void> saveImageBytes(Uint8List bytes, {required String name}) {
  return implementation.saveImageBytes(bytes, name: name);
}
