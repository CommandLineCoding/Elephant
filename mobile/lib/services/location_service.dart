import 'package:flutter/services.dart';

/// Where the phone is.
class DeviceLocation {
  final double lat;
  final double lon;

  /// How far off it may be, in metres, if known.
  final double? accuracy;

  const DeviceLocation(this.lat, this.lon, {this.accuracy});
}

/// Why a location couldn't be had.
enum LocationProblem {
  /// The person said no to the permission.
  denied,

  /// Location is switched off on the phone.
  disabled,

  /// No fix within about 20 seconds.
  unavailable,
}

/// The phone's location from Android's own location service (no Google Play
/// Services), asking for permission the first time.
class LocationService {
  static const _channel = MethodChannel('elephant/location');

  /// The current location, or why there isn't one.
  Future<({DeviceLocation? location, LocationProblem? problem})>
  current() async {
    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>('current');
      final lat = (reply?['lat'] as num?)?.toDouble();
      final lon = (reply?['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) {
        return (location: null, problem: LocationProblem.unavailable);
      }
      return (
        location: DeviceLocation(
          lat,
          lon,
          accuracy: (reply?['accuracy'] as num?)?.toDouble(),
        ),
        problem: null,
      );
    } on PlatformException catch (e) {
      return (
        location: null,
        problem: switch (e.code) {
          'denied' => LocationProblem.denied,
          'disabled' => LocationProblem.disabled,
          _ => LocationProblem.unavailable,
        },
      );
    } on MissingPluginException {
      return (location: null, problem: LocationProblem.unavailable);
    }
  }
}
