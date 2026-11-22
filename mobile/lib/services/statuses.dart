import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/message_envelope.dart';
import '../core/status_content.dart';
import '../models/inbox_item.dart';
import '../models/status.dart';
import 'api_services.dart';
import 'db_services.dart';
import 'signal_service.dart';

/// A status as the server holds it for this person: encrypted.
class RemoteStatus {
  final String id;
  final String authorId;
  final String content;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool viewed;

  const RemoteStatus({
    required this.id,
    required this.authorId,
    required this.content,
    required this.createdAt,
    required this.expiresAt,
    required this.viewed,
  });
}

/// One of the person's own statuses, as the server says: who has seen it.
class RemoteOwnStatus {
  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;
  final List<StatusViewer> viewers;

  const RemoteOwnStatus({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.viewers,
  });
}

/// What the server said about a status that was just posted.
class PostedStatus {
  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int recipients;

  const PostedStatus({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.recipients,
  });
}

/// The server's side of status. The app uses [ServerStatusRemote]; tests use
/// a fake.
abstract class StatusRemote {
  Future<List<RemoteStatus>> received();
  Future<List<RemoteOwnStatus>> own();
  Future<PostedStatus> post(List<Map<String, String>> copies);
  Future<void> delete(String id);
  Future<void> view(String id);
}

class ServerStatusRemote implements StatusRemote {
  ServerStatusRemote([ApiService? api]) : _api = api ?? ApiService();

  final ApiService _api;

  static DateTime _time(Object? v) =>
      DateTime.tryParse('$v')?.toLocal() ?? DateTime.now();

  @override
  Future<List<RemoteStatus>> received() async {
    final res = await _api.getStatuses();
    return [
      for (final raw in ApiService.dataList(res.data))
        if (raw is Map && raw['id'] is String && raw['author_id'] is String)
          RemoteStatus(
            id: (raw['id'] as String).toLowerCase(),
            authorId: (raw['author_id'] as String).toLowerCase(),
            content: '${raw['content']}',
            createdAt: _time(raw['created_at']),
            expiresAt: _time(raw['expires_at']),
            viewed: raw['viewed'] == true,
          ),
    ];
  }

  @override
  Future<List<RemoteOwnStatus>> own() async {
    final res = await _api.getOwnStatuses();
    return [
      for (final raw in ApiService.dataList(res.data))
        if (raw is Map && raw['id'] is String)
          RemoteOwnStatus(
            id: (raw['id'] as String).toLowerCase(),
            createdAt: _time(raw['created_at']),
            expiresAt: _time(raw['expires_at']),
            viewers: [
              for (final v in (raw['viewers'] as List? ?? const []))
                if (v is Map && v['user_id'] is String)
                  StatusViewer(
                    userId: (v['user_id'] as String).toLowerCase(),
                    viewedAt: _time(v['viewed_at']),
                  ),
            ],
          ),
    ];
  }

  @override
  Future<PostedStatus> post(List<Map<String, String>> copies) async {
    final data = ApiService.dataMap((await _api.postStatus(copies)).data);
    return PostedStatus(
      id: '${data['id']}'.toLowerCase(),
      createdAt: _time(data['created_at']),
      expiresAt: _time(data['expires_at']),
      recipients: (data['recipients'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> delete(String id) async {
    await _api.deleteStatus(id);
  }

  @override
  Future<void> view(String id) async {
    await _api.viewStatus(id);
  }
}

/// Where statuses are kept on this phone. The app uses its encrypted database;
/// tests use memory.
abstract class StatusStore {
  Future<List<StatusPost>> all();
  Future<void> save(StatusPost post);
  Future<void> markViewed(String id);
  Future<void> delete(String id);
  Future<void> deleteExpired(DateTime now);
}

class DatabaseStatusStore implements StatusStore {
  @override
  Future<List<StatusPost>> all() async => [
    for (final row in await DatabaseHelper.instance.statusRows())
      StatusPost.fromRow(row),
  ];

  @override
  Future<void> save(StatusPost post) =>
      DatabaseHelper.instance.saveStatus(post.toRow());

  @override
  Future<void> markViewed(String id) =>
      DatabaseHelper.instance.markStatusViewed(id);

  @override
  Future<void> delete(String id) => DatabaseHelper.instance.deleteStatus(id);

  @override
  Future<void> deleteExpired(DateTime now) =>
      DatabaseHelper.instance.deleteExpiredStatuses(now);
}

/// The encryption of a status: each person's copy is made like a direct
/// message to them.
abstract class StatusCrypto {
  /// Encrypts [plaintext] for [userId], or null if that person can't be
  /// written to yet (they haven't set up encryption).
  Future<String?> encrypt(String userId, String plaintext);

  /// The plaintext of [content] from [senderId], or null if it can't be read.
  Future<String?> decrypt(String senderId, String content);
}

class SignalStatusCrypto implements StatusCrypto {
  const SignalStatusCrypto();

  @override
  Future<String?> encrypt(String userId, String plaintext) async {
    try {
      final signal = SignalService();
      if (!await signal.establishSessionIfNeeded(userId)) return null;
      return await signal.encryptDirect(userId, plaintext);
    } catch (e) {
      debugPrint("Couldn't encrypt a status for $userId: $e");
      return null;
    }
  }

  @override
  Future<String?> decrypt(String senderId, String content) async {
    final text = await SignalService().decodeIncoming(senderId, content);
    return MessageEnvelope.isUnreadable(text) ? null : text;
  }
}

/// How posting went.
class StatusPostResult {
  /// Why it didn't go, or null if it did.
  final String? error;

  /// How many people got it, and how many of those it was meant for didn't.
  final int sent;
  final int skipped;

  const StatusPostResult({this.error, this.sent = 0, this.skipped = 0});
}

/// The people a status goes to: everyone the person chats with, as one to one,
/// except those who haven't been accepted (a message request) and anyone
/// blocked.
List<String> statusRecipients(
  Iterable<InboxItem> chats, {
  Set<String> blocked = const {},
}) {
  final out = <String>[];
  final seen = <String>{};
  for (final chat in chats) {
    if (chat.isGroup || chat.isRequest) continue;
    final id = chat.id.toLowerCase();
    if (blocked.contains(id) || !seen.add(id)) continue;
    out.add(id);
  }
  return out;
}

/// Statuses: short texts that last 24 hours, for the people a person chats
/// with. Each one is encrypted for each person, so the server never reads it.
/// What arrives is decrypted once and kept here, since a Signal message can't
/// be decrypted again.
class Statuses extends ChangeNotifier {
  Statuses({
    StatusStore? store,
    StatusRemote? remote,
    StatusCrypto? crypto,
    DateTime Function()? clock,
  }) : _store = store ?? DatabaseStatusStore(),
       _remote = remote ?? ServerStatusRemote(),
       _crypto = crypto ?? const SignalStatusCrypto(),
       _clock = clock ?? DateTime.now;

  /// The one the app uses. Tests replace it.
  static Statuses instance = Statuses();

  static const _mutedKey = 'status_muted';

  /// A status goes to at most this many people (the server's limit).
  static const maxRecipients = 200;

  final StatusStore _store;
  final StatusRemote _remote;
  final StatusCrypto _crypto;
  final DateTime Function() _clock;

  List<StatusPost> _posts = [];
  final Map<String, List<StatusViewer>> _viewers = {};
  Set<String> _muted = {};
  Future<void>? _loading;
  Future<void>? _refreshing;

  /// Reads what is kept on this phone, once.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final now = _clock();
      await _store.deleteExpired(now);
      final saved = await _store.all();
      final known = {for (final p in _posts) p.id};
      _posts = [
        ...saved.where((p) => !p.isExpired(now) && !known.contains(p.id)),
        ..._posts,
      ];
      final prefs = await SharedPreferences.getInstance();
      _muted = (prefs.getStringList(_mutedKey) ?? const []).toSet();
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't read statuses: $e");
      _loading = null;
    }
  }

  // --- What there is to show ---

  bool _live(StatusPost p) => !p.isExpired(_clock());

  /// [userId]'s statuses that can be shown, oldest first.
  List<StatusPost> postsBy(String userId) {
    final id = userId.toLowerCase();
    return [
      for (final p in _posts)
        if (p.authorId.toLowerCase() == id && p.content != null && _live(p)) p,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// Everyone else's statuses, by person: those with something new first, then
  /// the most recent. People whose status is muted are left out.
  List<({String authorId, List<StatusPost> posts, bool unseen})> others(
    String myId,
  ) {
    final me = myId.toLowerCase();
    final byAuthor = <String, List<StatusPost>>{};
    for (final p in _posts) {
      final id = p.authorId.toLowerCase();
      if (id == me || p.content == null || !_live(p) || _muted.contains(id)) {
        continue;
      }
      byAuthor.putIfAbsent(id, () => []).add(p);
    }
    final out = [
      for (final e in byAuthor.entries)
        (
          authorId: e.key,
          posts: e.value..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
          unseen: e.value.any((p) => !p.viewed),
        ),
    ];
    out.sort((a, b) {
      if (a.unseen != b.unseen) return a.unseen ? -1 : 1;
      return b.posts.last.createdAt.compareTo(a.posts.last.createdAt);
    });
    return out;
  }

  /// Who has seen the person's own status [id].
  List<StatusViewer> viewersOf(String id) =>
      List.unmodifiable(_viewers[id.toLowerCase()] ?? const []);

  bool isMuted(String userId) => _muted.contains(userId.toLowerCase());

  // --- Getting them ---

  /// Fetches what is new from the server. Safe to call often: calls that
  /// overlap share one fetch.
  Future<void> refresh(String myId) =>
      _refreshing ??= _refresh(myId).whenComplete(() => _refreshing = null);

  Future<void> _refresh(String myId) async {
    await load();
    final me = myId.toLowerCase();
    try {
      final remote = await _remote.received();
      final onServer = {for (final r in remote) r.id};
      final local = {for (final p in _posts) p.id: p};
      for (final r in remote) {
        final have = local[r.id];
        if (have == null) {
          await _receive(r);
        } else if (r.viewed && !have.viewed) {
          await _setViewed(have);
        } else if (have.viewed && !r.viewed) {
          // Seen here while offline: tell the server now.
          unawaited(_tellServerSeen(r.id));
        }
      }
      // What its author took down early goes from here too.
      for (final p in List.of(_posts)) {
        if (p.authorId.toLowerCase() != me && !onServer.contains(p.id)) {
          await _drop(p.id);
        }
      }
    } catch (e) {
      debugPrint("Couldn't fetch statuses: $e");
    }

    try {
      final own = await _remote.own();
      final onServer = {for (final o in own) o.id};
      _viewers
        ..clear()
        ..addEntries(own.map((o) => MapEntry(o.id, o.viewers)));
      for (final p in List.of(_posts)) {
        if (p.authorId.toLowerCase() == me && !onServer.contains(p.id)) {
          await _drop(p.id);
        }
      }
    } catch (e) {
      debugPrint("Couldn't fetch your statuses: $e");
    }

    try {
      await _store.deleteExpired(_clock());
    } catch (_) {}
    _posts = [
      for (final p in _posts)
        if (_live(p)) p,
    ];
    notifyListeners();
  }

  Future<void> _receive(RemoteStatus r) async {
    String? plain;
    try {
      plain = await _crypto.decrypt(r.authorId, r.content);
    } catch (e) {
      debugPrint("Couldn't read a status: $e");
    }
    final post = StatusPost(
      id: r.id,
      authorId: r.authorId,
      // Kept even when unreadable, so it isn't tried again.
      content: plain == null ? null : StatusContent.tryParse(plain),
      createdAt: r.createdAt,
      expiresAt: r.expiresAt,
      viewed: r.viewed,
    );
    _posts = [..._posts, post];
    try {
      await _store.save(post);
    } catch (e) {
      debugPrint("Couldn't save a status: $e");
    }
  }

  Future<void> _drop(String id) async {
    _posts = _posts.where((p) => p.id != id).toList();
    _viewers.remove(id);
    try {
      await _store.delete(id);
    } catch (_) {}
  }

  Future<void> _setViewed(StatusPost post) async {
    _posts = [
      for (final p in _posts) p.id == post.id ? p.copyWith(viewed: true) : p,
    ];
    try {
      await _store.markViewed(post.id);
    } catch (_) {}
  }

  Future<void> _tellServerSeen(String id) async {
    try {
      await _remote.view(id);
    } catch (e) {
      debugPrint("Couldn't tell the server a status was seen: $e");
    }
  }

  // --- Posting, viewing, deleting ---

  /// Posts [text] as the person's status, encrypted for each of [recipients]
  /// (user IDs; use [statusRecipients]).
  Future<StatusPostResult> post({
    required String myId,
    required String text,
    required int background,
    required int font,
    required List<String> recipients,
  }) async {
    final content = StatusContent(
      text: StatusContent.clean(text),
      background: background,
      font: font,
    );
    if (content.text.isEmpty) {
      return const StatusPostResult(error: 'Write something first.');
    }
    final targets = recipients.take(maxRecipients).toList();
    if (targets.isEmpty) {
      return const StatusPostResult(
        error:
            'Chat with someone first: a status goes to the people you chat with.',
      );
    }

    final plaintext = content.encode();
    final copies = <Map<String, String>>[];
    for (final id in targets) {
      final sealed = await _crypto.encrypt(id, plaintext);
      if (sealed != null) copies.add({'recipient_id': id, 'content': sealed});
    }
    if (copies.isEmpty) {
      return const StatusPostResult(
        error:
            'No one you chat with has set up encryption yet, so nobody could get it.',
      );
    }

    final PostedStatus posted;
    try {
      posted = await _remote.post(copies);
    } catch (e) {
      return StatusPostResult(
        error: ApiService.errorMessage(
          e,
          fallback: "Couldn't post your status.",
        ),
      );
    }
    final mine = StatusPost(
      id: posted.id,
      authorId: myId.toLowerCase(),
      content: content,
      createdAt: posted.createdAt,
      expiresAt: posted.expiresAt,
      viewed: true,
    );
    _posts = [..._posts, mine];
    try {
      await _store.save(mine);
    } catch (e) {
      debugPrint("Couldn't save your status: $e");
    }
    notifyListeners();
    return StatusPostResult(
      sent: posted.recipients,
      skipped: targets.length - posted.recipients,
    );
  }

  /// The person is looking at [post]: it counts as seen, here and for its
  /// author (if the person allows read receipts the server tells them). The
  /// person's own statuses start out seen.
  Future<void> markViewed(StatusPost post) async {
    if (post.viewed) return;
    await _setViewed(post);
    notifyListeners();
    await _tellServerSeen(post.id);
  }

  /// Takes the person's own status down for everyone. Returns an error to show,
  /// or null.
  Future<String?> delete(StatusPost post) async {
    try {
      await _remote.delete(post.id);
    } catch (e) {
      // Already gone is as good as done.
      final gone = e is DioException && e.response?.statusCode == 404;
      if (!gone) {
        return ApiService.errorMessage(
          e,
          fallback: "Couldn't delete your status.",
        );
      }
    }
    await _drop(post.id);
    notifyListeners();
    return null;
  }

  Future<void> mute(String userId) => _setMuted(userId, true);

  Future<void> unmute(String userId) => _setMuted(userId, false);

  Future<void> _setMuted(String userId, bool muted) async {
    final id = userId.toLowerCase();
    if (muted ? !_muted.add(id) : !_muted.remove(id)) return;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        _mutedKey,
        _muted.toList(),
      );
    } catch (e) {
      debugPrint("Couldn't save muted statuses: $e");
    }
  }

  /// Forgets everything held in memory, at sign-out.
  void reset() {
    _posts = [];
    _viewers.clear();
    _muted = {};
    _loading = null;
    _refreshing = null;
    notifyListeners();
  }
}
