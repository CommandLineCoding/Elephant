import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'links.dart';
import 'message_payload.dart';

/// A link's title, description and site, worked out on the sender's phone and
/// sent inside the encrypted message. The receiver never visits the link, so
/// the website can't see who read the message (see "Structured messages" in
/// docs/API_CONTRACTS.md).
class LinkPreview {
  final String url;
  final String title;
  final String? description;
  final String? site;

  const LinkPreview({
    required this.url,
    required this.title,
    this.description,
    this.site,
  });

  static const maxUrl = 500;
  static const maxTitle = 120;
  static const maxDescription = 200;
  static const maxSite = 60;

  /// Reads a `preview` payload that came with [messageText]. The preview is
  /// only shown if its link really is a link in the text, so a preview can't
  /// make a message look like it points somewhere it doesn't.
  static LinkPreview? fromPayload(
    MessagePayload? payload, {
    required String messageText,
  }) {
    if (payload == null || payload.kind != 'preview') return null;
    final url = payload.field<String>('url');
    final title = payload.field<String>('title')?.trim();
    if (url == null || url.length > maxUrl) return null;
    if (title == null || title.isEmpty || title.length > maxTitle * 2) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    if (!linksIn(messageText).contains(url)) return null;

    String? clip(String? s, int max) {
      final t = s?.trim();
      return t == null || t.isEmpty ? null : _clip(t, max);
    }

    return LinkPreview(
      url: url,
      title: _clip(title, maxTitle),
      description: clip(payload.field<String>('desc'), maxDescription),
      site: clip(payload.field<String>('site'), maxSite),
    );
  }

  Map<String, dynamic> toData() => {
    'url': url,
    'title': title,
    if (description != null) 'desc': description,
    if (site != null) 'site': site,
  };

  /// The site to show: its name if the page gave one, else its address.
  String get siteLabel => site ?? Uri.tryParse(url)?.host ?? '';

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1).trimRight()}…';

  /// Works out a preview of [url] from the page's [html], or null if it has
  /// no title.
  static LinkPreview? parseHtml(String url, String html) {
    final metas = <String, String>{};
    for (final tag in _metaTag.allMatches(html)) {
      final attrs = <String, String>{};
      for (final a in _attribute.allMatches(tag[1]!)) {
        attrs[a[1]!.toLowerCase()] = a[2] ?? a[3] ?? a[4] ?? '';
      }
      final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
      final content = attrs['content'];
      if (key != null && content != null) metas.putIfAbsent(key, () => content);
    }

    String? tidy(String? raw, int max) {
      if (raw == null) return null;
      final text = _decodeEntities(
        raw.replaceAll(RegExp(r'<[^>]*>'), ''),
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      return text.isEmpty ? null : _clip(text, max);
    }

    final pageTitle = _titleTag.firstMatch(html)?[1];
    final title =
        tidy(metas['og:title'] ?? metas['twitter:title'], maxTitle) ??
        tidy(pageTitle, maxTitle);
    if (title == null) return null;
    return LinkPreview(
      url: url,
      title: title,
      description: tidy(
        metas['og:description'] ??
            metas['description'] ??
            metas['twitter:description'],
        maxDescription,
      ),
      site: tidy(metas['og:site_name'], maxSite),
    );
  }

  // A quoted value can contain ">" (a title like "A > B"), so quotes are
  // matched whole instead of stopping at the first ">".
  static final _metaTag = RegExp(
    r'''<meta\s+((?:"[^"]*"|'[^']*'|[^>"'])*?)/?>''',
    caseSensitive: false,
    dotAll: true,
  );
  static final _attribute = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
  );
  static final _titleTag = RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  );

  static String _decodeEntities(String s) {
    const named = {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'nbsp': ' ',
      'ndash': '–',
      'mdash': '—',
      'hellip': '…',
      'rsquo': '’',
      'lsquo': '‘',
      'rdquo': '”',
      'ldquo': '“',
    };
    return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (
      m,
    ) {
      final entity = m[1]!;
      if (entity.startsWith('#')) {
        final code = entity.startsWith('#x')
            ? int.tryParse(entity.substring(2), radix: 16)
            : int.tryParse(entity.substring(1));
        if (code == null || code <= 0 || code > 0x10FFFF) return m[0]!;
        return String.fromCharCode(code);
      }
      return named[entity] ?? m[0]!;
    });
  }
}

/// Whether a link previews are fetched. On unless switched off, since
/// fetching shows the website the sender's address.
class LinkPreviewPrefs {
  static const _key = 'link_previews';

  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  static Future<void> setEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_key, value);
}

/// Whether [address] is on the public internet. Previews never go to the
/// phone's own network, or to this phone.
bool isPublicAddress(InternetAddress address) {
  if (address.isLoopback ||
      address.isLinkLocal ||
      address.isMulticast ||
      address.rawAddress.every((b) => b == 0)) {
    return false;
  }
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    if (b[0] == 10) return false;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return false;
    if (b[0] == 192 && b[1] == 168) return false;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false; // shared/CGNAT
    if (b[0] == 169 && b[1] == 254) return false;
    if (b[0] == 0 || b[0] >= 240) return false;
    return true;
  }
  if ((b[0] & 0xfe) == 0xfc) return false; // unique local fc00::/7
  // ::ffff:a.b.c.d is an IPv4 address in disguise.
  final mapped =
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) {
    return isPublicAddress(
      InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
    );
  }
  return true;
}

/// Whether [uri] is something previews may be fetched from: https, a real
/// host name or public address, no login in the address, the usual port.
bool isFetchableUri(Uri uri) {
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return false;
  }
  if (uri.hasPort && uri.port != 443) return false;
  final host = uri.host.toLowerCase();
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return isPublicAddress(literal);
  return host.contains('.') &&
      host != 'localhost' &&
      !host.endsWith('.localhost') &&
      !host.endsWith('.local') &&
      !host.endsWith('.internal') &&
      !host.endsWith('.lan');
}

/// What a web request gave back.
class PageResponse {
  final int status;
  final String? contentType;
  final String? location;
  final Stream<List<int>> body;

  /// Called when the response has been read as far as it will be.
  final void Function()? close;

  const PageResponse({
    required this.status,
    required this.body,
    this.contentType,
    this.location,
    this.close,
  });
}

typedef PageGetter = Future<PageResponse> Function(Uri uri);
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// Fetches a link's page and makes a [LinkPreview] of it, carefully: https
/// only, public addresses only (checked again at every redirect), a few
/// redirects, a short wait and a small download.
class LinkPreviewFetcher {
  LinkPreviewFetcher({
    PageGetter? get,
    HostResolver? resolve,
    this.timeout = const Duration(seconds: 8),
  }) : _get = get ?? _httpGet,
       _resolve = resolve ?? InternetAddress.lookup;

  /// The one the app uses. Tests replace it.
  static LinkPreviewFetcher shared = LinkPreviewFetcher();

  final PageGetter _get;
  final HostResolver _resolve;

  static const maxBytes = 64 * 1024;
  static const maxRedirects = 3;

  /// How long a whole preview may take, redirects included.
  final Duration timeout;

  /// The preview of [url], or null if there isn't a safe, readable one. The
  /// preview keeps [url] itself, not where redirects led.
  Future<LinkPreview?> fetch(String url) async {
    try {
      return await _fetch(url).timeout(timeout);
    } catch (e) {
      debugPrint('No link preview: $e');
      return null;
    }
  }

  Future<LinkPreview?> _fetch(String url) async {
    var uri = Uri.tryParse(url);
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (uri == null || !isFetchableUri(uri)) return null;
      if (InternetAddress.tryParse(uri.host) == null) {
        final addresses = await _resolve(uri.host);
        if (addresses.isEmpty || !addresses.every(isPublicAddress)) {
          return null;
        }
      }

      final response = await _get(uri);
      try {
        if ({301, 302, 303, 307, 308}.contains(response.status)) {
          final next = response.location;
          uri = next == null ? null : uri.resolve(next);
          continue;
        }
        if (response.status != 200) return null;
        final type = response.contentType?.toLowerCase() ?? '';
        if (!type.contains('text/html') && !type.contains('xhtml')) {
          return null;
        }
        final html = await _readHead(response.body);
        return LinkPreview.parseHtml(url, html);
      } finally {
        response.close?.call();
      }
    }
    return null;
  }

  Future<String> _readHead(Stream<List<int>> body) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body) {
      bytes.add(chunk);
      if (bytes.length >= maxBytes) break;
    }
    final all = bytes.takeBytes();
    return utf8.decode(
      all.length > maxBytes ? all.sublist(0, maxBytes) : all,
      allowMalformed: true,
    );
  }

  static Future<PageResponse> _httpGet(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..userAgent = 'Mozilla/5.0 (compatible; Elephant link preview)';
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml',
      );
      final response = await request.close();
      return PageResponse(
        status: response.statusCode,
        contentType: response.headers.contentType?.toString(),
        location: response.headers.value(HttpHeaders.locationHeader),
        body: response,
        close: () => client.close(force: true),
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}
