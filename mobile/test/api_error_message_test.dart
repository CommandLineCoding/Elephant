import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/api_services.dart';

DioException _error(int status, dynamic data) {
  final options = RequestOptions(path: '/messages/1');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: options, statusCode: status, data: data),
  );
}

void main() {
  group('ApiService.errorMessage', () {
    test('prefers the server error field', () {
      final message = ApiService.errorMessage(
        _error(404, {'success': false, 'error': 'message not found'}),
      );
      expect(message, 'Message not found');
    });

    test('explains a missing route on an older server', () {
      final message = ApiService.errorMessage(
        _error(404, '404 page not found'),
        fallback: "Couldn't edit the message.",
      );
      expect(message, contains('may need updating'));
    });

    test('falls back for other failures', () {
      final message = ApiService.errorMessage(
        _error(500, 'boom'),
        fallback: "Couldn't edit the message.",
      );
      expect(message, "Couldn't edit the message.");
    });
  });
}
