// lib/pages/session_view_page.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

class SessionViewArgs {
  final String bucket;
  final String deviceId;
  final String dateFolder;
  final String tsFolder;
  final Map<String, dynamic>? analytics;
  final List<Uint8List> images; // decoded image bytes
  final List<String> imageNames; // filenames
  final Uint8List? audioWav;

  SessionViewArgs({
    required this.bucket,
    required this.deviceId,
    required this.dateFolder,
    required this.tsFolder,
    required this.analytics,
    required this.images,
    required this.imageNames,
    required this.audioWav,
  });
}

Future<void> pushSessionViewer(BuildContext ctx, SessionViewArgs args) async {
  await Navigator.of(ctx).push(
    MaterialPageRoute(builder: (_) => SessionViewPage(args: args)),
  );
}

class SessionViewPage extends StatefulWidget {
  const SessionViewPage({super.key, required this.args});
  final SessionViewArgs args;

  @override
  State<SessionViewPage> createState() => _SessionViewPageState();
}

class _SessionViewPageState extends State<SessionViewPage> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  // Keep it SDK-safe: avoid JsonEncoder.withIndent (some toolchains complained).
  String _pretty(Map<String, dynamic> j) {
    final raw = const JsonEncoder().convert(j);
    final s1 = raw.replaceAll(',\"', ',\n\"');
    final s2 = s1.replaceAll(':{', ': {\n').replaceAll('},', '\n},');
    return s2;
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.args;
    final pad = MediaQuery.of(context).size.width < 420 ? 12.0 : 16.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Viewer'),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, 12, pad, 24),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('Device: ${a.deviceId}')),
              Chip(label: Text('Date: ${a.dateFolder}')),
              Chip(label: Text('Session: ${a.tsFolder}')),
              Chip(label: Text('Bucket: ${a.bucket}')),
            ],
          ),
          const SizedBox(height: 12),

          // Analytics
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Analytics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (a.analytics != null)
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(
                          _pretty(a.analytics!),
                          style: const TextStyle(fontFamily: 'monospace', height: 1.3),
                        ),
                      ),
                    )
                  else
                    const Text('No analytics.json in this session.'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Images
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Images (${a.images.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (a.images.isEmpty)
                    const Text('No images in this session.')
                  else
                    GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: a.images.length,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemBuilder: (ctx, i) {
                        final bytes = a.images[i];
                        final name = (i < a.imageNames.length) ? a.imageNames[i] : 'image_$i';
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(bytes, fit: BoxFit.cover),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Audio
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Audio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (a.audioWav == null)
                    const Text('No WAV found in this session.')
                  else
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            if (_playing) {
                              await _player.stop();
                              setState(() => _playing = false);
                              return;
                            }
                            try {
                              await _player.play(BytesSource(a.audioWav!));
                              setState(() => _playing = true);
                              _player.onPlayerComplete.first.then((_) {
                                if (mounted) setState(() => _playing = false);
                              });
                            } catch (_) {}
                          },
                          icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                          label: Text(_playing ? 'Stop' : 'Play'),
                        ),
                        const SizedBox(width: 12),
                        const Text('WAV from session'),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}