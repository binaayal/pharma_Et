import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/api/tenant_api.dart';

/// A payment screenshot is sent as the image it is. Found on a phone: without a type the part
/// went as application/octet-stream and the server refused every proof.
void main() {
  test('names its image type', () {
    expect(imageTypeOf('scaled_receipt.png').mimeType, 'image/png');
    expect(imageTypeOf('IMG_2031.JPG').mimeType, 'image/jpeg');
    expect(imageTypeOf('shot.webp').mimeType, 'image/webp');
    expect(imageTypeOf('no-extension').mimeType, 'image/jpeg');
  });
}
