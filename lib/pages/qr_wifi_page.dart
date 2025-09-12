// lib/pages/qr_wifi_page.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QrWifiPage extends StatefulWidget {
  const QrWifiPage({super.key});

  @override
  State<QrWifiPage> createState() => _QrWifiPageState();
}

class _QrWifiPageState extends State<QrWifiPage> {
  final _formKey = GlobalKey<FormState>();
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isWpa = true; // WPA/WPA2 by default
  bool _hidden = false;
  bool _showQr = false;

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  String _wifiPayload() {
    // Wi‑Fi QR spec: WIFI:T:<WEP|WPA|nopass>;S:<ssid>;P:<password>;H:true;;
    String esc(String s) =>
        s.replaceAll(r'\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,');
    final t = _isWpa ? 'WPA' : (_passCtrl.text.isEmpty ? 'nopass' : 'WEP');
    final s = esc(_ssidCtrl.text.trim());
    final p = esc(_passCtrl.text);
    final h = _hidden ? ';H:true' : '';
    final pPart = t == 'nopass' ? '' : ';P:$p';
    return 'WIFI:T:$t;S:$s$pPart$h;;';
  }

  void _generate() {
    if (_formKey.currentState?.validate() ?? false) {
      setState(() => _showQr = true);
    }
  }

  double _qrSize(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    // Keep padding in mind; make the QR responsive and avoid overflow
    return math.max(180, math.min(320, w - 64));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi‑Fi QR')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        children: [
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _ssidCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Wi‑Fi SSID',
                        hintText: 'Your network name',
                        prefixIcon: Icon(Icons.wifi),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter SSID' : null,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        hintText: 'Leave empty for open network',
                        prefixIcon: Icon(Icons.lock),
                      ),
                      textInputAction: TextInputAction.done,
                    ),
                    const SizedBox(height: 12),

                    // Responsive security + hidden controls (no overflow)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isNarrow = constraints.maxWidth < 420;
                        final securityField = DropdownButtonFormField<bool>(
                          value: _isWpa,
                          items: const [
                            DropdownMenuItem(
                                value: true, child: Text('WPA/WPA2')),
                            DropdownMenuItem(
                                value: false, child: Text('WEP / Open')),
                          ],
                          onChanged: (v) => setState(() => _isWpa = v ?? true),
                          decoration: const InputDecoration(
                            labelText: 'Security',
                            prefixIcon: Icon(Icons.security),
                          ),
                        );
                        final hiddenSwitch = SwitchListTile.adaptive(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Hidden SSID'),
                          value: _hidden,
                          onChanged: (v) => setState(() => _hidden = v),
                        );

                        if (isNarrow) {
                          // Stack vertically on small screens
                          return Column(
                            children: [
                              securityField,
                              const SizedBox(height: 8),
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: hiddenSwitch),
                            ],
                          );
                        } else {
                          // Place side by side with safe expansion
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(child: securityField),
                              const SizedBox(width: 12),
                              // Wrap switch to avoid taking infinite width
                              Flexible(
                                fit: FlexFit.loose,
                                child: hiddenSwitch,
                              ),
                            ],
                          );
                        }
                      },
                    ),

                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('Generate QR'),
                        onPressed: _generate,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_showQr) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                children: [
                  QrImageView(
                    data: _wifiPayload(),
                    size: _qrSize(context),
                    backgroundColor: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Point your SensePi camera at this code',
                    style: TextStyle(color: cs.onSurface.withOpacity(0.7)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}