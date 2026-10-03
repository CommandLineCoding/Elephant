import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/ui/glass.dart';

import 'core/constants.dart';
import 'services/auth_service.dart';
import 'pages/auth/login_page.dart';
import 'pages/home/home_page.dart';
import 'controllers/auth_state.dart';

import 'controllers/chat/active_chat_controller.dart';
import 'controllers/chat/chat_connection_controller.dart';
import 'controllers/chat/chat_search_controller.dart';
import 'controllers/chat/group_details_controller.dart';
import 'controllers/chat/inbox_controller.dart';
import 'services/chat/chat_event_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Env.init();
  await AuthService().initTokens();

  final themeProvider = ThemeProvider();
  await themeProvider.load();

  final authState = AuthState();
  String currentUserId() => authState.currentUser?.id ?? '';

  final inboxController = InboxController();
  final activeChatController = ActiveChatController()
    ..currentUserIdProvider = currentUserId;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider.value(value: authState),
        ChangeNotifierProvider(create: (_) => GroupController()),
        ChangeNotifierProvider.value(value: inboxController),
        ChangeNotifierProvider.value(value: activeChatController),
        ChangeNotifierProvider(create: (_) => ChatSearchController()),
        ChangeNotifierProvider(create: (_) => GroupDetailsController()),
        ChangeNotifierProvider(
          create: (_) => ChatConnectionController(
            eventHandler: ChatEventHandler(
              inboxController: inboxController,
              activeChatController: activeChatController,
              currentUserIdProvider: currentUserId,
            ),
          ),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Elephant',
      debugShowCheckedModeBanner: false,
      theme: context.watch<ThemeProvider>().themeData,
      themeAnimationDuration: const Duration(milliseconds: 350),
      home: const SessionGateway(),
    );
  }
}

class SessionGateway extends StatefulWidget {
  const SessionGateway({super.key});

  @override
  State<SessionGateway> createState() => _SessionGatewayState();
}

class _SessionGatewayState extends State<SessionGateway> {
  bool _hasCheckedAutoLogin = false;
  String? _lastInitializedToken;

  @override
  void initState() {
    super.initState();
    _performInitialAutoLoginCheck();
  }

  void _initChatSession() {
    context.read<ChatConnectionController>().connectWebSocket();
    context.read<InboxController>().loadInbox();
  }

  void _performInitialAutoLoginCheck() async {
    final token = await context.read<AuthState>().checkAutoLogin();

    if (token != null && mounted) {
      _lastInitializedToken = token;
      _initChatSession();
    }

    if (mounted) setState(() => _hasCheckedAutoLogin = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasCheckedAutoLogin) return const _Splash();

    final authState = context.watch<AuthState>();
    final token = authState.token;

    if (token != null && _lastInitializedToken == null) {
      _lastInitializedToken = token;
      WidgetsBinding.instance.addPostFrameCallback((_) => _initChatSession());
    } else if (token == null) {
      _lastInitializedToken = null;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: token != null
          ? const HomePage(key: ValueKey('home'))
          : const LoginPage(key: ValueKey('login')),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AmbientBackground(
        child: Center(
          child: Image.asset(
            'assets/launcher/elephant.png',
            width: 96,
            height: 96,
          ),
        ),
      ),
    );
  }
}
