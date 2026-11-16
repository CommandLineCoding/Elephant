import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/core/profile_links.dart';
import 'package:mobile/core/qr_codes.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';

/// Scans someone's Elephant QR code and opens the chat with them.
///
/// The camera permission is asked for here, when scanning starts, not at
/// install or launch.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  CameraController? _camera;
  String? _error;
  String? _hint;
  Timer? _hintTimer;
  bool _decoding = false;
  bool _done = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'This device has no camera.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      await camera.startImageStream(_onFrame);
      setState(() => _camera = camera);
    } on CameraException catch (e) {
      final denied = e.code.startsWith('CameraAccess');
      setState(
        () => _error = denied
            ? 'Elephant needs the camera to scan codes. Allow camera access '
                  'for Elephant in Android settings, then try again.'
            : 'Couldn\'t start the camera.',
      );
    }
  }

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (_done ||
        _decoding ||
        now.difference(_lastFrame) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastFrame = now;
    _decoding = true;
    final plane = image.planes.first;
    final text = decodeQr(
      plane.bytes,
      width: image.width,
      height: image.height,
      rowStride: plane.bytesPerRow,
    );
    _decoding = false;
    if (text == null || !mounted) return;

    final username = usernameFromQr(text);
    if (username == null) {
      _showHint("That's not an Elephant code");
      return;
    }
    _done = true;
    HapticFeedback.mediumImpact();
    _camera?.stopImageStream();
    Navigator.pop(context);
    // The home screen opens the chat, as for a profile link.
    ProfileLinks.instance.pending.value = username;
  }

  void _showHint(String hint) {
    _hintTimer?.cancel();
    setState(() => _hint = hint);
    _hintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan a code'),
      ),
      body: _error != null
          ? ColoredBox(
              color: context.theme.scaffoldBackgroundColor,
              child: EmptyState(
                icon: Icons.no_photography_outlined,
                title: 'Can\'t use the camera',
                message: _error!,
                actionLabel: 'Try again',
                onAction: _start,
              ),
            )
          : camera == null || !camera.value.isInitialized
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(child: CameraPreview(camera)),
                Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(Radii.lg),
                    ),
                  ),
                ),
                Positioned(
                  left: Insets.xl,
                  right: Insets.xl,
                  bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
                  child: Text(
                    _hint ?? "Point the camera at someone's Elephant QR code",
                    textAlign: TextAlign.center,
                    style: context.text.bodyLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
