import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/glass.dart';

void showSnack(BuildContext context, String message, {bool isError = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (isError) ...[
              Icon(
                Icons.error_outline_rounded,
                color: context.colors.error,
                size: 20,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Frosted bottom sheet with a grab handle and optional title.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: GlassSurface(
          strong: true,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.xl),
          ),
          child: SafeArea(
            top: false,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 6),
                      width: 40,
                      height: 4.5,
                      decoration: BoxDecoration(
                        color: sheetContext.colors.onSurfaceVariant.withValues(
                          alpha: 0.35,
                        ),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Insets.xl,
                        Insets.sm,
                        Insets.xl,
                        Insets.sm,
                      ),
                      child: Text(title, style: sheetContext.text.titleLarge),
                    ),
                  Flexible(child: builder(sheetContext)),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// One entry of [showActionSheet].
class SheetAction<T> {
  final IconData icon;
  final String label;
  final T value;
  final bool destructive;

  const SheetAction({
    required this.icon,
    required this.label,
    required this.value,
    this.destructive = false,
  });
}

Future<T?> showActionSheet<T>(
  BuildContext context, {
  required List<SheetAction<T>> actions,
  Widget? header,
}) {
  return showGlassSheet<T>(
    context,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          for (final action in actions)
            ListTile(
              leading: Icon(
                action.icon,
                color: action.destructive
                    ? sheetContext.colors.error
                    : sheetContext.colors.onSurface,
              ),
              title: Text(
                action.label,
                style: TextStyle(
                  color: action.destructive ? sheetContext.colors.error : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () => Navigator.pop(sheetContext, action.value),
            ),
        ],
      ),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: dialogContext.colors.error,
                  foregroundColor: dialogContext.colors.onError,
                  minimumSize: const Size(88, 44),
                )
              : FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

/// Asks for a single line of text. Returns null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? message,
  String initialValue = '',
  String hint = '',
  String confirmLabel = 'Save',
  bool obscure = false,
  int? maxLength,
}) {
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) ...[
            Text(message),
            const SizedBox(height: Insets.lg),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            maxLength: maxLength,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}
