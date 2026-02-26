import 'auth_api.dart';
import 'auth_session_manager.dart';

/// Returns a sanitized, filesystem-safe key scoped to the current user.
/// Returns 'guest' when no user is authenticated.
Future<String> storeUserKey() async {
  final userId =
      AuthSessionManager.instance.currentUserValue?.id.trim() ?? '';
  if (userId.isEmpty) return 'guest';
  return userId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}

/// Executes [action] with the current access token.
/// On a 401 error, refreshes the token once and retries.
/// Returns null when no valid token exists or after exhausting retries.
/// Re-throws exceptions when [silent] is false.
Future<T?> withAuthRetry<T>({
  required Future<T> Function(String token) action,
  bool silent = true,
}) async {
  final token = AuthSessionManager.instance.accessToken?.trim() ?? '';
  if (token.isEmpty) return null;

  try {
    return await action(token);
  } on AuthApiException catch (error) {
    if (error.statusCode == 401) {
      final refreshed =
          await AuthSessionManager.instance.refreshWithStoredToken();
      if (refreshed) {
        final retryToken =
            AuthSessionManager.instance.accessToken?.trim() ?? '';
        if (retryToken.isNotEmpty) {
          try {
            return await action(retryToken);
          } catch (_) {
            if (!silent) rethrow;
            return null;
          }
        }
      }
      if (!silent) rethrow;
      return null;
    }
    if (!silent) rethrow;
    return null;
  } catch (_) {
    if (!silent) rethrow;
    return null;
  }
}
