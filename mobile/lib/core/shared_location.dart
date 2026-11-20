import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'message_payload.dart';

/// A place shared in a chat.
class SharedLocation {
  final double lat;
  final double lon;

  /// How far off it may be, in metres, if the sender's phone said.
  final double? accuracy;

  const SharedLocation(this.lat, this.lon, {this.accuracy});

  /// Reads a `location` payload, or null if it isn't a real place. It came
  /// from someone else, so the numbers are checked.
  static SharedLocation? fromPayload(MessagePayload? payload) {
    if (payload == null || payload.kind != 'location') return null;
    final lat = payload.field<num>('lat')?.toDouble();
    final lon = payload.field<num>('lon')?.toDouble();
    final accuracy = payload.field<num>('acc')?.toDouble();
    if (lat == null || lon == null) return null;
    if (!lat.isFinite || !lon.isFinite) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return SharedLocation(
      lat,
      lon,
      accuracy: accuracy != null && accuracy.isFinite && accuracy >= 0
          ? accuracy
          : null,
    );
  }

  /// Coordinates are sent to about a metre.
  static String _fmt(double v) => v.toStringAsFixed(5);

  String get coordinates => '${_fmt(lat)}, ${_fmt(lon)}';

  /// A map page anyone can open, in the text older apps show.
  Uri get webLink => Uri.https('www.openstreetmap.org', '/', {
    'mlat': _fmt(lat),
    'mlon': _fmt(lon),
  }).replace(fragment: 'map=16/${_fmt(lat)}/${_fmt(lon)}');

  /// Android's own map link: opens whichever maps app the person has.
  Uri get geoLink =>
      Uri.parse('geo:${_fmt(lat)},${_fmt(lon)}?q=${_fmt(lat)},${_fmt(lon)}');

  (Map<String, dynamic>, String) toPayload() => (
    {
      'lat': double.parse(_fmt(lat)),
      'lon': double.parse(_fmt(lon)),
      if (accuracy != null) 'acc': accuracy!.roundToDouble(),
    },
    '📍 Location: $coordinates\n$webLink',
  );
}

typedef UriLauncher = Future<bool> Function(Uri uri);

/// Replaces the launcher in tests.
@visibleForTesting
UriLauncher? debugUriLauncher;

Future<bool> _launch(Uri uri) => (debugUriLauncher ?? _launchExternal)(uri);

Future<bool> _launchExternal(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Couldn't open $uri: $e");
    return false;
  }
}

/// Opens [location] in the phone's maps app, or in a browser on OpenStreetMap
/// if it has none. The links are built here from checked numbers, never taken
/// from the message. Returns false if nothing could open it.
Future<bool> openInMaps(SharedLocation location) async {
  if (await _launch(location.geoLink)) return true;
  return _launch(location.webLink);
}
