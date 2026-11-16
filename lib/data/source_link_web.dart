import 'package:web/web.dart' as web;

bool openSourceLink(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return false;
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  return true;
}
