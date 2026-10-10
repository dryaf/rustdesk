import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;
import 'package:flutter_hbb/utils/local_url.dart' as urls;

void main() {
  test('LAN build refuses HTTP services', () async {
    final url = Uri.parse('https://example.com');
    await expectLater(http.get(url), throwsUnsupportedError);
    await expectLater(http.post(url), throwsUnsupportedError);
    await expectLater(http.put(url), throwsUnsupportedError);
    await expectLater(http.delete(url), throwsUnsupportedError);
  });

  test('LAN build refuses external URL launches', () async {
    for (final url in [
      'https://rustdesk.com',
      'http://192.168.1.1',
      'ftp://example.com',
      'file://example.com/shared/file',
      'mailto:someone@example.com',
    ]) {
      expect(await urls.canLaunchUrlString(url), isFalse);
      expect(await urls.launchUrlString(url), isFalse);
    }
    expect(await urls.canLaunchUrlString('file:///tmp/recordings'), isTrue);
  });
}
