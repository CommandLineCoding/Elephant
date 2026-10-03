import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../models/user.dart';
import '../../services/api_services.dart';

/// User directory search (`GET /api/users/search`, rate limited server-side).
class ChatSearchController extends ChangeNotifier {
  final ApiService _api = ApiService();

  List<UserModel> results = [];
  bool isSearchLoading = false;
  bool isLoadingMore = false;
  bool hasMore = false;
  String? error;

  String _query = '';
  int _page = 1;
  int _requestId = 0;

  static const int minQueryLength = 2;

  Future<void> queryUsers(String term) async {
    final query = term.trim();
    final requestId = ++_requestId;
    _query = query;
    _page = 1;
    error = null;

    if (query.length < minQueryLength) {
      results = [];
      hasMore = false;
      isSearchLoading = false;
      notifyListeners();
      return;
    }

    isSearchLoading = true;
    notifyListeners();

    try {
      final page = await _fetch(query, 1);
      if (requestId != _requestId) return;
      results = page;
      hasMore = page.length >= ServerLimits.searchPageSize;
    } catch (e) {
      if (requestId != _requestId) return;
      results = [];
      error = ApiService.errorMessage(e, fallback: "Search failed.");
    } finally {
      if (requestId == _requestId) {
        isSearchLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (!hasMore || isLoadingMore || isSearchLoading) return;
    final requestId = _requestId;
    isLoadingMore = true;
    notifyListeners();

    try {
      final page = await _fetch(_query, _page + 1);
      if (requestId != _requestId) return;
      _page++;
      final known = results.map((u) => u.id).toSet();
      results = [...results, ...page.where((u) => !known.contains(u.id))];
      hasMore = page.length >= ServerLimits.searchPageSize;
    } catch (e) {
      error = ApiService.errorMessage(e, fallback: "Search failed.");
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<List<UserModel>> _fetch(String query, int page) async {
    final res = await _api.searchUsers(query, page: page);
    return ApiService.dataList(res.data)
        .map((json) => UserModel.fromJson(Map<String, dynamic>.from(json)))
        .toList();
  }

  void clearSearch() {
    _requestId++;
    _query = '';
    results = [];
    hasMore = false;
    error = null;
    isSearchLoading = false;
    notifyListeners();
  }
}
