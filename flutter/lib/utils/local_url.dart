import 'package:url_launcher/url_launcher.dart' as launcher;
export 'package:url_launcher/url_launcher.dart' show LaunchMode;

bool _isLocalFile(Uri url) => url.scheme == 'file' && url.host.isEmpty;

Future<bool> launchUrl(Uri url,
    {launcher.LaunchMode mode = launcher.LaunchMode.platformDefault}) async {
  if (!_isLocalFile(url)) return false;
  return launcher.launchUrl(url, mode: mode);
}

Future<bool> launchUrlString(String url) => launchUrl(Uri.parse(url));

Future<bool> canLaunchUrlString(String url) async => _isLocalFile(Uri.parse(url));
