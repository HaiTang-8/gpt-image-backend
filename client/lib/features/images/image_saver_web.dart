import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const String imageSaveSuccessMessage = '已开始下载图片';

Future<void> saveImageBytes(Uint8List bytes, {required String name}) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'image/png'),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    web.HTMLAnchorElement()
      ..href = url
      ..download = '$name.png'
      ..click();
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
