import 'package:flutter/material.dart';

import '../../core/poll.dart';
import '../../themes/app_themes.dart';
import '../../widgets/ui/components.dart';

/// Writes a poll: a question, 2–10 options, and whether people can pick more
/// than one. Pops with the [PollData] to send.
class CreatePollPage extends StatefulWidget {
  const CreatePollPage({super.key});

  @override
  State<CreatePollPage> createState() => _CreatePollPageState();
}

class _CreatePollPageState extends State<CreatePollPage> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multi = false;
  String? _problem;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    if (_options.length >= PollData.maxOptions) return;
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_options.length <= PollData.minOptions) return;
    setState(() => _options.removeAt(index).dispose());
  }

  void _send() {
    final texts = [for (final c in _options) c.text];
    final problem = PollData.problemWith(_question.text, texts);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(
      context,
      PollData(_question.text.trim(), [
        for (final t in texts)
          if (t.trim().isNotEmpty) t.trim(),
      ], multi: _multi),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New poll'),
        actions: [
          TextButton(onPressed: _send, child: const Text('Send')),
          const SizedBox(width: Insets.sm),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Insets.page),
        children: [
          const SectionLabel('Question'),
          TextField(
            controller: _question,
            maxLength: PollData.maxQuestionLength,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Ask a question'),
            onChanged: (_) => setState(() => _problem = null),
          ),
          const SizedBox(height: Insets.lg),
          const SectionLabel('Options'),
          for (var i = 0; i < _options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _options[i],
                      maxLength: PollData.maxOptionLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Option ${i + 1}',
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() => _problem = null),
                    ),
                  ),
                  if (_options.length > PollData.minOptions)
                    IconButton(
                      tooltip: 'Remove option ${i + 1}',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _removeOption(i),
                    ),
                ],
              ),
            ),
          if (_options.length < PollData.maxOptions)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addOption,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add option'),
              ),
            ),
          const SizedBox(height: Insets.md),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow multiple answers'),
            value: _multi,
            onChanged: (value) => setState(() => _multi = value),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Text(
                _problem!,
                style: TextStyle(color: context.colors.error),
              ),
            ),
        ],
      ),
    );
  }
}
