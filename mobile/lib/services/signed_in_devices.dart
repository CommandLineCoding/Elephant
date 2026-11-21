import '../models/signed_in_device.dart';
import 'api_services.dart';

/// The server calls behind the Signed-in devices screen. A class so a test can
/// stand in for the server.
abstract class SignedInDevicesApi {
  Future<List<SignedInDevice>> list();
  Future<void> signOut(String id);
  Future<void> signOutOthers();
}

class ServerSignedInDevicesApi implements SignedInDevicesApi {
  const ServerSignedInDevicesApi();

  @override
  Future<List<SignedInDevice>> list() async {
    final res = await ApiService().getSessions();
    return [
      for (final entry in ApiService.dataList(res.data))
        if (SignedInDevice.fromJson(entry) case final device?) device,
    ];
  }

  @override
  Future<void> signOut(String id) async {
    await ApiService().signOutSession(id);
  }

  @override
  Future<void> signOutOthers() async {
    await ApiService().signOutOtherSessions();
  }
}
