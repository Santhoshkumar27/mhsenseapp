// lib/pages/s3_session_page.dart
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:minio/minio.dart';

import 'session_view_page.dart';

// Simple holder for image key + bytes

class _Img {
  final String key;
  final Uint8List bytes;
  _Img(this.key, this.bytes);
}

// Candidate holder for a device/date/ts moment
class _Moment {
  final String device;
  final String date;
  final String ts;
  final String prefix; // fully qualified prefix we will try
  final int rank;      // 0=processed,1=direct,2=queued (prefer lower)
  _Moment(this.device, this.date, this.ts, this.prefix, this.rank);
}

class S3SessionPage extends StatefulWidget {
  const S3SessionPage({super.key});

  @override
  State<S3SessionPage> createState() => _S3SessionPageState();
}

class _S3SessionPageState extends State<S3SessionPage> {
  // Form fields
  final _bucketCtl = TextEditingController(text: 'microheal');
  final _regionCtl = TextEditingController(text: 'ap-south-1');
  final _deviceManualCtl = TextEditingController();

  // Device/date/time drop-downs
  List<String> _devices = [];
  String? _selectedDevice;
  bool _loadingDevices = false;

  List<String> _dates = [];
  List<String> _times = [];
  String? _selectedDate;
  String? _selectedTime;

  bool _busy = false;
  String? _latestPrefix; // e.g. DEV/(processed|queued/)?YYYY-MM-DD/TS/
  Map<String, dynamic>? _analytics;
  List<_Img> _images = [];
  Uint8List? _wavBytes;
  SessionViewArgs? _lastArgs;

  // Helper: recognize date and timestamp folder names
  bool _isDate(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);
  bool _isTs(String s) => RegExp(r'^\d{8}_\d{6}$').hasMatch(s);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
  }

  @override
  void dispose() {
    _bucketCtl.dispose();
    _regionCtl.dispose();
    _deviceManualCtl.dispose();
    _dates.clear();
    _times.clear();
    super.dispose();
  }

  // ===== TEMP credentials for setup (replace with --dart-define in production) =====
  static const String _AK_DEFAULT = '';
  static const String _SK_DEFAULT = '';
  static const String _AK = String.fromEnvironment('S3_AK', defaultValue: _AK_DEFAULT);
  static const String _SK = String.fromEnvironment('S3_SK', defaultValue: _SK_DEFAULT);

  // ===== MinIO/S3 client =====
  Future<Minio> _mkS3() async {
    final regionTxt = _regionCtl.text.trim();
    final region = regionTxt.isEmpty ? 'ap-south-1' : regionTxt;
    if (_AK.isEmpty || _SK.isEmpty) {
      throw ArgumentError(
          'Missing AWS keys. Build with --dart-define=S3_AK=... --dart-define=S3_SK=...');
    }
    final endpoint = 's3.$region.amazonaws.com';
    debugPrint('[S3] Using AK=${_AK.length >= 4 ? _AK.substring(0,4) : _AK}… region=$region endpoint=$endpoint');
    debugPrint('[S3] Bucket=${_bucketCtl.text.trim()} Region=$region (virtual-hosted)');
    return Minio(
      endPoint: endpoint,
      accessKey: _AK,
      secretKey: _SK,
      useSSL: true,
      region: region,
    );
  }

  // ===== Device/date/time discovery =====
  Future<void> _loadDevices() async {
    const bucket = 'microheal';
    _bucketCtl.text = bucket;
    setState(() {
      _loadingDevices = true;
      _devices = [];
      _selectedDevice = null;
      _dates = [];
      _times = [];
      _selectedDate = null;
      _selectedTime = null;
    });
    try {
      final s3 = await _mkS3();
      final prefixes = await _listPrefixes(s3, bucket, '');
      if (prefixes.isEmpty) {
        // Inference fallback for buckets without CommonPrefixes
        final inferred = <String>{};
        await for (final obj in s3.listObjects(bucket, prefix: '', recursive: true)) {
          final k = _objKeyDyn(obj);
          if (k.isEmpty || k.startsWith('/')) continue;
          final idx = k.indexOf('/');
          if (idx > 0) inferred.add(k.substring(0, idx) + '/');
          if (inferred.length >= 200) break;
        }
        prefixes.addAll(inferred);
      }
      final rawNames = prefixes
          .map((p) => p.endsWith('/') ? p.substring(0, p.length - 1) : p)
          .toSet()
          .toList();

      final hexLike = RegExp(r'^[0-9a-f]{10,16}$', caseSensitive: false);
      final names = rawNames.where((n) => hexLike.hasMatch(n)).toList()..sort();

      setState(() {
        _devices = names;
        _selectedDevice = _devices.isNotEmpty ? _devices.first : null;
      });

      if (_selectedDevice == null) {
        _snack('No devices found in bucket "$bucket". Type device ID manually.');
      }
    } catch (e) {
      _snack('Load devices failed: $e');
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  Future<void> _loadDatesForDevice(String device) async {
    const bucket = 'microheal';
    try {
      final s3 = await _mkS3();
      final root = '${device.trim()}/';
      final dates = <String>{};

      await for (final obj in s3.listObjects(bucket, prefix: root, recursive: true)) {
        final k = _objKeyDyn(obj);
        if (k.isEmpty) continue;
        final rel = k.startsWith(root) ? k.substring(root.length) : k;
        final parts = rel.split('/');
        if (parts.isEmpty) continue;

        int dateIdx = 0;
        if (parts[0] == 'queued' || parts[0] == 'processed') {
          if (parts.length < 2) continue;
          dateIdx = 1;
        }
        final date = parts.length > dateIdx ? parts[dateIdx] : '';
        if (_isDate(date)) dates.add(date);
      }
      final list = dates.toList()..sort();
      setState(() {
        _dates = list;
        _selectedDate = _dates.isNotEmpty ? _dates.last : null; // newest
        _times = [];
        _selectedTime = null;
      });
      if (_selectedDate != null) {
        await _loadTimesForDate(device, _selectedDate!);
      }
    } catch (e) {
      _snack('Load dates failed: $e');
    }
  }

  Future<void> _loadTimesForDate(String device, String date) async {
    const bucket = 'microheal';
    try {
      final s3 = await _mkS3();
      final times = <String, String>{}; // ts -> chosen root
      final dev = device.trim();
      final dt  = date.trim();

      final rootProcessed = '$dev/processed/$dt/';
      final rootDirect    = '$dev/$dt/';
      final rootQueued    = '$dev/queued/$dt/';

      Future<void> scan(String root, int rank) async {
        await for (final obj in s3.listObjects(bucket, prefix: root, recursive: true)) {
          final k = _objKeyDyn(obj);
          if (k.isEmpty) continue;
          final rel = k.startsWith(root) ? k.substring(root.length) : k;
          final ts = rel.split('/').first;
          if (!_isTs(ts)) continue;
          final existing = times[ts];
          if (existing == null) {
            times[ts] = root;
          } else {
            final existingRank = existing == rootProcessed ? 0 : (existing == rootDirect ? 1 : 2);
            if (rank < existingRank) times[ts] = root;
          }
        }
      }

      await scan(rootProcessed, 0);
      await scan(rootDirect,    1);
      await scan(rootQueued,    2);

      // after we've filled `times` (Map<String, String> ts -> root)
      final list = times.keys.toList()
        ..sort((a, b) => b.compareTo(a)); // newest first
      setState(() {
        _times = list;
        _selectedTime = _times.isNotEmpty ? _times.first : null; // pick newest
      });

      if (_selectedTime != null) {
        final chosenRoot = times[_selectedTime!];
        if (chosenRoot != null) {
          _snack('Session $_selectedTime from ' +
              (chosenRoot.contains('/processed/') ? 'processed'
                  : chosenRoot.contains('/queued/') ? 'queued'
                  : 'direct'));
        }
      } else {
        _snack('No sessions found on $date for $device.');
      }
    } catch (e) {
      _snack('Load sessions failed: $e');
    }
  }

  // Helper: parse device/date/ts from a prefix string.
  (String device, String date, String ts) _parsePrefix(String prefix) {
    var p = prefix;
    if (p.startsWith('/')) p = p.substring(1);
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final parts = p.split('/');
    // device/date/ts OR device/(queued|processed)/date/ts
    if (parts.length >= 3) {
      final device = parts[0];
      if (parts.length >= 4 && (parts[1] == 'queued' || parts[1] == 'processed')) {
        return (device, parts[2], parts[3]);
      } else {
        return (device, parts[1], parts[2]);
      }
    }
    return ('', '', '');
  }

  Future<void> _fetchLatest() async {
    const bucket = 'microheal';
    _bucketCtl.text = bucket;

    final manual = _deviceManualCtl.text.trim();
    final device = manual.isNotEmpty ? manual : (_selectedDevice?.trim() ?? '');
    if (device.isEmpty) {
      _snack('Please select or type a device ID.');
      return;
    }

    setState(() {
      _busy = true;
      _analytics = null;
      _images = [];
      _wavBytes = null;
      _latestPrefix = null;
    });

    try {
      final s3 = await _mkS3();

      // Gather newest candidate moments across processed/direct/queued
      final candidates = await _findLatestCandidatesByScan(s3, bucket, device, maxCandidates: 8);
      debugPrint('[S3] candidates=${candidates.length}' + (candidates.isNotEmpty ? ' newest=${candidates.first.date}/${candidates.first.ts}' : ''));
      if (candidates.isEmpty) {
        _snack('No sessions found for $device.');
        return;
      }

      List<String> keys = const [];
      String? chosenPrefix;
      String dev = '', dt = '', tsf = '';

      for (final m in candidates) {
        dev = m.device; dt = m.date; tsf = m.ts;
        chosenPrefix = m.prefix;
        setState(() => _latestPrefix = chosenPrefix);

        // Try union across sibling roots
        keys = await _listAllForMoment(s3, bucket, device: dev, date: dt, ts: tsf);

        debugPrint('[S3] candidate ${m.date}/${m.ts} (rank=${m.rank}) -> ${keys.length} keys');
        if (keys.isNotEmpty && !(keys.length == 1 && keys.first.toLowerCase().endsWith('/analytics.json'))) {
          break; // good enough
        }

        // Try presence reconstruction
        if (keys.isEmpty || (keys.length == 1 && keys.first.toLowerCase().endsWith('/analytics.json'))) {
          final presKeys = await _probePresenceAndConstructKeys(s3, bucket, device: dev, date: dt, ts: tsf);
          if (presKeys.isNotEmpty) {
            keys = presKeys;
            break;
          }
        }

        // Try brute probe
        if (keys.isEmpty || (keys.length == 1 && keys.first.toLowerCase().endsWith('/analytics.json'))) {
          final brute = await _bruteProbeMedia(s3, bucket, device: dev, date: dt, ts: tsf, beforeSecs: 10, afterSecs: 120);
          if (brute.isNotEmpty) {
            keys = brute;
            break;
          }
        }

        // Otherwise, loop to next newest candidate
      }

      if (keys.isEmpty) {
        _snack('Newest sessions have no visible media yet. Try again in a few seconds.');
        return;
      }

      final latest = chosenPrefix ?? '${dev.trim()}/$dt/$tsf/';

      debugPrint('[S3] listing for latest="$latest" returned ${keys.length} keys');
      if (keys.isNotEmpty) {
        debugPrint('[S3] first=${keys.first} last=${keys.last}');
      }

      // If listing returned nothing or just analytics.json, reconstruct keys using session_presence.json
      if (keys.isEmpty || (keys.length == 1 && keys.first.toLowerCase().endsWith('/analytics.json'))) {
        if (dev.isNotEmpty && dt.isNotEmpty && tsf.isNotEmpty) {
          final presKeys = await _probePresenceAndConstructKeys(
            s3,
            bucket,
            device: dev,
            date: dt,
            ts: tsf,
          );
          if (presKeys.isNotEmpty) {
            keys = presKeys;
            debugPrint('[S3][presence] using reconstructed keys (${keys.length})');
          }
        }
      }

      // FINAL fallback: brute probe by guessing names (no ListBucket needed)
      if (keys.isEmpty || (keys.length == 1 && keys.first.toLowerCase().endsWith('/analytics.json'))) {
        if (dev.isNotEmpty && dt.isNotEmpty && tsf.isNotEmpty) {
          final brute = await _bruteProbeMedia(
            s3,
            bucket,
            device: dev,
            date: dt,
            ts: tsf,
            beforeSecs: 10,
            afterSecs: 90,
          );
          if (brute.isNotEmpty) {
            keys = brute;
            debugPrint('[S3][brute] using guessed keys (${keys.length})');
          }
        }
      }

      await _loadSessionFiles(s3, bucket, keys);

      // Build viewer args
      final imgBytes = _images.map<Uint8List>((e) => e.bytes).toList();
      final imgNames = _images.map<String>((e) => e.key.split('/').last).toList();
      final args = SessionViewArgs(
        bucket: 'microheal',
        deviceId: dev.isNotEmpty ? dev : device,
        dateFolder: dt,
        tsFolder: tsf,
        analytics: _analytics,
        images: imgBytes,       // union fixed
        imageNames: imgNames,
        audioWav: _wavBytes,
      );
      setState(() => _lastArgs = args);
      if (mounted) {
        await pushSessionViewer(context, args);
      }
    } catch (e) {
      _snack('S3 error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSessionFiles(Minio s3, String bucket, List<String> keys) async {
    final analyticsCandidates = keys.where((k) {
      final lk = k.toLowerCase();
      return lk.endsWith('analytics.json') || lk.endsWith('session_presence.json') || lk.endsWith('presence.jsonl') || lk.endsWith('.json');
    }).toList();
    final analyticsKey = analyticsCandidates.firstWhere(
      (k) => k.toLowerCase().endsWith('analytics.json'),
      orElse: () => (analyticsCandidates.isNotEmpty ? analyticsCandidates.first : ''),
    );

    final wavKey = keys.firstWhere(
      (k) => k.toLowerCase().endsWith('.wav'),
      orElse: () => '',
    );

    final imageKeys = keys
        .where((k) {
          final lk = k.toLowerCase();
          return lk.endsWith('.jpg') || lk.endsWith('.jpeg') || lk.endsWith('.png');
        })
        .toList()
      ..sort();

    debugPrint('[S3] keys total=${keys.length} imgs=${imageKeys.length} wav=${wavKey.isNotEmpty} analytics=${analyticsKey.isNotEmpty}');

    String? errNote;

    // analytics
    if (analyticsKey.isNotEmpty) {
      try {
        final bytes = await _getObjectBytes(s3, bucket, analyticsKey);
        final txt = String.fromCharCodes(bytes);
        _analytics = txt.isNotEmpty ? (await _safeDecodeJson(txt)) : null;
      } catch (e) {
        errNote = (errNote == null) ? 'analytics: $e' : '$errNote, analytics: $e';
        debugPrint('[S3] analytics download failed for $analyticsKey: $e');
      }
    }

    // Load all images for now (to diagnose missing media); sort oldest->newest
    final maxImagesList = imageKeys; // already sorted ascending
    if (maxImagesList.isNotEmpty) {
      debugPrint('[S3] first img=${maxImagesList.first} last img=${maxImagesList.last}');
    }
    final imgs = <_Img>[];
    for (final k in maxImagesList) {
      try {
        final bytes = await _getObjectBytes(s3, bucket, k);
        imgs.add(_Img(k, bytes));
      } catch (e) {
        errNote = (errNote == null) ? 'images: $e' : '$errNote, images: $e';
        debugPrint('[S3] image download failed for $k: $e');
      }
    }

    // audio
    Uint8List? wav;
    if (wavKey.isNotEmpty) {
      try {
        wav = await _getObjectBytes(s3, bucket, wavKey);
      } catch (e) {
        errNote = (errNote == null) ? 'audio: $e' : '$errNote, audio: $e';
        debugPrint('[S3] audio download failed for $wavKey: $e');
      }
    }

    if (mounted) {
      debugPrint('[S3] loaded imgs=${imgs.length} wav=${wav != null} analytics=${_analytics != null}');
      setState(() {
        _images = imgs;
        _wavBytes = wav;
      });
      final info = '${imgs.length} image${imgs.length == 1 ? '' : 's'}' + (wav != null ? ' + audio' : '');
      if (imgs.isNotEmpty || wav != null || _analytics != null) {
        _snack('Loaded $info');
      }
      if (errNote != null) {
        _snack('Some session files failed to download ($errNote).');
      } else if (imgs.isEmpty && wav == null && _analytics == null) {
        _snack('Session found but contains no images/audio/analytics.');
      }
    }
  }

  // ===== MinIO helpers =====
  Future<Uint8List> _getObjectBytes(Minio s3c, String bucket, String key) async {
    final b = BytesBuilder(copy: false);
    final stream = await s3c.getObject(bucket, key);
    await for (final chunk in stream) {
      b.add(chunk);
    }
    final out = b.takeBytes();
    debugPrint('[S3] getObject size for $bucket/$key = ${out.length}');
    return out;
  }
    // Extract media-looking keys from any JSON structure
    List<String> _extractMediaFromJson(dynamic node) {
      final out = <String>{};
      void walk(dynamic n) {
        if (n is Map) {
          n.forEach((k, v) {
            if (k is String) {
              final lk = k.toLowerCase();
              if (lk.endsWith('.jpg') || lk.endsWith('.jpeg') || lk.endsWith('.png') || lk.endsWith('.wav')) {
                out.add(k);
              }
            }
            walk(v);
          });
        } else if (n is List) {
          for (final e in n) walk(e);
        } else if (n is String) {
          final s = n.trim();
          final ls = s.toLowerCase();
          if (ls.endsWith('.jpg') || ls.endsWith('.jpeg') || ls.endsWith('.png') || ls.endsWith('.wav')) {
            out.add(s);
          }
        }
      }
      walk(node);
      return out.toList()..sort();
    }

// Try to fetch session_presence.json from each sibling root and build a full key list
    Future<List<String>> _probePresenceAndConstructKeys(
        Minio s3,
        String bucket, {
          required String device,
          required String date,
          required String ts,
        }) async {
      final candidates = <String>[
        '${device.trim()}/processed/$date/$ts/session_presence.json',
        '${device.trim()}/queued/$date/$ts/session_presence.json',
        '${device.trim()}/$date/$ts/session_presence.json',
      ];
      for (final key in candidates) {
        try {
          final bytes = await _getObjectBytes(s3, bucket, key);
          final txt = String.fromCharCodes(bytes);
          final dyn = await _safeDecodeJson(txt);
          if (dyn != null) {
            final media = _extractMediaFromJson(dyn);

            final out = <String>{};
            // include the presence file itself
            out.add(key);

            // media keys may be bare filenames or full S3 keys — normalize to full keys beside presence file
            final root = key.substring(0, key.lastIndexOf('/') + 1);
            for (final m in media) {
              if (m.contains('/')) {
                out.add(m);
              } else {
                out.add(root + m);
              }
            }

            // Also try common audio names for this moment in all three roots
            final roots = <String>[
              '${device.trim()}/$date/$ts/',
              '${device.trim()}/processed/$date/$ts/',
              '${device.trim()}/queued/$date/$ts/',
            ];
            for (final r in roots) {
              out.add('${r}audio_${ts}.wav');
              out.add('${r}audio_${ts}_enhanced.wav');
            }

            final list = out.toList()..sort();
            debugPrint('[S3][presence] parsed ${media.length} media entries, constructed ${list.length} keys');
            return list;
          }
        } catch (e) {
          debugPrint('[S3][presence] miss for $key: $e');
        }
      }
      return const <String>[];
    }

  // ---- Time helpers for brute probe (avoid ListBucket limits) ----
  DateTime _tsToDateTime(String date, String ts) {
    // date: YYYY-MM-DD, ts: YYYYMMDD_HHMMSS
    final d = date.split('-').map(int.parse).toList(); // [YYYY, MM, DD]
    final t = ts.split('_');
    final ymd = t[0];
    final hms = t.length > 1 ? t[1] : '000000';
    final hh = int.parse(hms.substring(0,2));
    final mm = int.parse(hms.substring(2,4));
    final ss = int.parse(hms.substring(4,6));
    return DateTime.utc(d[0], d[1], d[2], hh, mm, ss);
  }

  String _fmtTs(DateTime dt) {
    String two(int x) => x.toString().padLeft(2, '0');
    final y = dt.year.toString().padLeft(4, '0');
    final m = two(dt.month);
    final d = two(dt.day);
    final hh = two(dt.hour);
    final mm = two(dt.minute);
    final ss = two(dt.second);
    return '${y}${m}${d}_${hh}${mm}${ss}';
  }

  Future<List<String>> _bruteProbeMedia(
    Minio s3,
    String bucket, {
      required String device,
      required String date,
      required String ts,
      int beforeSecs = 10,
      int afterSecs = 75,
    }) async {
    // Try to discover objects WITHOUT listObjects, by probing likely names.
    // We use statObject (HEAD) to avoid downloading bytes.
    final keys = <String>{};

    Future<bool> _exists(String k) async {
      try {
        await s3.statObject(bucket, k);
        return true;
      } catch (_) {
        return false;
      }
    }

    // Always try analytics/presence direct names across sibling roots
    final baseRoots = <String>[
      '${device.trim()}/$date/$ts/',
      '${device.trim()}/processed/$date/$ts/',
      '${device.trim()}/queued/$date/$ts/',
    ];
    for (final r in baseRoots) {
      for (final name in <String>[
        'analytics.json',
        'session_presence.json',
        'presence.jsonl',
        'audio_${ts}.wav',
        'audio_${ts}_enhanced.wav',
      ]) {
        final k = '$r$name';
        if (await _exists(k)) keys.add(k);
      }
    }

    // Probe photos in a sliding window around ts (common pattern: shots taken within ~1 min)
    final t0 = _tsToDateTime(date, ts);
    for (int s = -beforeSecs; s <= afterSecs; s++) {
      final t = t0.add(Duration(seconds: s));
      final candTs = _fmtTs(t);
      for (final r in baseRoots) {
        final k = '${r}photo_${candTs}.jpg';
        if (await _exists(k)) keys.add(k);
      }
    }

    final out = keys.toList()..sort();
    debugPrint('[S3][brute] discovered ${out.length} keys without listing for $device/$date/$ts');
    return out;
  }



  // robust extractor for different ListObjects shapes
  String _objKeyDyn(dynamic obj) {
    try { final k = (obj as dynamic).key; if (k is String && k.isNotEmpty) return k; } catch (_) {}
    try { final n = (obj as dynamic).name; if (n is String && n.isNotEmpty) return n; } catch (_) {}
    try { final on = (obj as dynamic).objectName; if (on is String && on.isNotEmpty) return on; } catch (_) {}
    try { final it = (obj as dynamic).item; if (it != null) { final ik = (it as dynamic).key; if (ik is String && ik.isNotEmpty) return ik; }} catch (_) {}
    try {
      final s = obj.toString();
      final keyIdx = s.indexOf('key: ');
      if (keyIdx >= 0) {
        final after = s.substring(keyIdx + 5);
        final cut = after.indexOf(',');
        final end = cut >= 0 ? cut : after.indexOf('}');
        final raw = (end >= 0 ? after.substring(0, end) : after).trim();
        if (raw.isNotEmpty) return raw;
      }
      if (s.contains('/') && !s.endsWith('}')) return s.trim();
    } catch (_) {}
    return '';
  }

  Future<List<String>> _listPrefixes(Minio s3, String bucket, String prefix) async {
    final out = <String>{};
    await for (final obj in s3.listObjects(bucket, prefix: prefix, recursive: true)) {
      final key = _objKeyDyn(obj);
      if (key.isEmpty) continue;
      if (!key.startsWith(prefix)) continue;
      final rel = key.substring(prefix.length);
      if (rel.isEmpty) continue;
      final slash = rel.indexOf('/');
      if (slash >= 0) {
        final child = rel.substring(0, slash + 1);
        if (prefix.isEmpty && (child == 'queued/' || child == 'processed/')) continue;
        out.add(prefix + child);
      }
    }
    final list = out.toList()..sort();
    return list;
  }

  Future<List<String>> _listAllObjects(Minio s3, String bucket, String prefix) async {
    // Normalize prefix (no leading slash; ensure trailing slash for "folder" semantics)
    var pfx = prefix.trim();
    if (pfx.startsWith('/')) pfx = pfx.substring(1);
    if (pfx.isNotEmpty && !pfx.endsWith('/')) pfx = '$pfx/';

    final set = <String>{};

    Future<void> scan(String p) async {
      await for (final obj in s3.listObjects(bucket, prefix: p, recursive: true)) {
        var k = _objKeyDyn(obj);
        if (k.isEmpty) continue;

        // Clean up odd returns like starting slash, quotes, or stray spaces
        k = k.trim();
        if (k.startsWith('"') && k.endsWith('"') && k.length > 1) {
          k = k.substring(1, k.length - 1);
        }
        if (k.startsWith('/')) k = k.substring(1);

        // Accept if it looks like a file
        if (k.endsWith('/')) {
          continue; // skip folders
        }

        // Be permissive about prefix matching: sometimes SDKs return full or relative keys.
        final matches =
            (p.isEmpty) ||
            k.startsWith(p) ||
            k.contains('/$p') ||
            (k.contains(p) && p.length >= 3);

        if (matches) {
          set.add(k);
        } else {
          // Log a few non-matching keys for diagnosis
          debugPrint('[S3][skip] key="$k" not under prefix="$p"');
        }
      }
    }

    // Primary scan with normalized prefix
    await scan(pfx);

    // Diagnostic: if only analytics.json is visible, ListBucket may be restricted by IAM.
    if (set.length == 1) {
      final only = set.first.toLowerCase();
      if (only.endsWith('/analytics.json')) {
        debugPrint(
          '[S3][diag] Only analytics.json visible under "$pfx". '
          'Likely IAM restricts ListBucket to analytics.json. '
          'Grant s3:ListBucket on the bucket and s3:GetObject on microheal/*.'
        );
      }
    }

    // Fallbacks: try without trailing slash and with original prefix as-is
    if (set.isEmpty && pfx.isNotEmpty) {
      final noTrail = pfx.endsWith('/') ? pfx.substring(0, pfx.length - 1) : pfx;
      debugPrint('[S3] fallback scan no-trailing-slash "$noTrail"');
      await scan(noTrail);
    }
    if (set.isEmpty && prefix.trim().isNotEmpty && prefix.trim() != pfx) {
      debugPrint('[S3] fallback scan original "$prefix"');
      await scan(prefix.trim());
    }

    final out = set.toList()..sort();
    return out;
  }

  Future<List<String>> _listAllForMoment(
      Minio s3,
      String bucket, {
        required String device,
        required String date,
        required String ts,
      }) async {
    final roots = <String>[
      '${device.trim()}/processed/$date/$ts/',
      '${device.trim()}/queued/$date/$ts/',
      '${device.trim()}/$date/$ts/',
    ];

    final union = <String>{};
    for (final r in roots) {
      final keys = await _listAllObjects(s3, bucket, r);
      debugPrint('[S3] probe root="$r" -> ${keys.length} keys');
      union.addAll(keys);
    }
    final out = union.toList()..sort();
    debugPrint('[S3] union for $device/$date/$ts -> ${out.length} keys');
    // Fallback: if we only saw analytics.json or nothing, do a bucket-wide scan
    // and filter locally for this moment. This sidesteps any server-side ListBucket
    // prefix restrictions.
    if (out.length <= 1) {
      int added = 0;
      await for (final obj in s3.listObjects(bucket, recursive: true)) {
        final kRaw = _objKeyDyn(obj);
        if (kRaw.isEmpty || kRaw.endsWith('/')) continue;
        final kTrim = kRaw.trim();
        final k = kTrim.startsWith('/') ? kTrim.substring(1) : kTrim;

        // Accept keys that clearly belong to this moment across any sibling root
        if (k.contains('$device/$date/$ts/') ||
            k.contains('$device/processed/$date/$ts/') ||
            k.contains('$device/queued/$date/$ts/')) {
          union.add(k);
          added++;
        }
      }
      final widened = union.toList()..sort();
      debugPrint('[S3][fallback] widened to ${widened.length} keys for $device/$date/$ts (added $added)');
      if (widened.isNotEmpty) {
        debugPrint('[S3][fallback] first=${widened.first} last=${widened.last}');
      }
      return widened;
    }
    return out;
  }

  // Returns a list of newest candidate moments (device/date/ts) with their best prefix/rank.
  Future<List<_Moment>> _findLatestCandidatesByScan(
      Minio s3, String bucket, String device, {int maxCandidates = 6}) async {
    final dev = device.trim();
    final root = '$dev/';

    debugPrint('[S3] scan for latest (device=$device)');

    // We'll track newest moments by (date, ts) with their best rank.
    final Map<String, _Moment> bestByKey = {};

    void consider({required String date, required String ts, required int rank}) {
      if (!_isDate(date) || !_isTs(ts)) return;
      final key = '$date/$ts';
      final existing = bestByKey[key];
      final prefix = (rank == 0)
          ? '${root}processed/$date/$ts/'
          : (rank == 2)
              ? '${root}queued/$date/$ts/'
              : '${root}$date/$ts/';
      if (existing == null || rank < existing.rank) {
        bestByKey[key] = _Moment(dev, date, ts, prefix, rank);
      }
    }

    // Pass 1: scan under device root (fast path)
    await for (final obj in s3.listObjects(bucket, prefix: root, recursive: true)) {
      final fullKey = _objKeyDyn(obj);
      if (fullKey.isEmpty || fullKey.endsWith('/')) continue;
      final rel = fullKey.startsWith(root) ? fullKey.substring(root.length) : fullKey;
      final parts = rel.split('/');
      if (parts.length < 3) continue;

      if (parts[0] == 'processed' && parts.length >= 4) {
        consider(date: parts[1], ts: parts[2], rank: 0);
      } else if (parts[0] == 'queued' && parts.length >= 4) {
        consider(date: parts[1], ts: parts[2], rank: 2);
      } else {
        consider(date: parts[0], ts: parts[1], rank: 1);
      }
    }

    // Pass 2: bucket-wide safety scan (handles prefix quirks/IAM filtering)
    await for (final obj in s3.listObjects(bucket, recursive: true)) {
      var k = _objKeyDyn(obj);
      if (k.isEmpty || k.endsWith('/')) continue;
      k = k.trim();
      if (k.startsWith('/')) k = k.substring(1);

      final devSeg = '$dev/';
      int ix;
      if (k.startsWith(devSeg)) {
        ix = 0;
      } else {
        ix = k.indexOf('/$dev/');
        if (ix >= 0) ix += 1;
      }
      if (ix < 0) continue;

      final after = k.substring(ix + devSeg.length);
      final parts = after.split('/');
      if (parts.length < 3) continue;

      if (parts[0] == 'processed' && parts.length >= 4) {
        consider(date: parts[1], ts: parts[2], rank: 0);
      } else if (parts[0] == 'queued' && parts.length >= 4) {
        consider(date: parts[1], ts: parts[2], rank: 2);
      } else {
        consider(date: parts[0], ts: parts[1], rank: 1);
      }
    }

    // If we still have nothing, probe recent dates (today..7 days back) narrowly
    if (bestByKey.isEmpty) {
      final recent = await _findLatestCandidatesByRecentDates(s3, bucket, device, daysBack: 7);
      if (recent.isNotEmpty) {
        debugPrint('[S3] candidates(recent)=${recent.length}');
        return (recent.length > maxCandidates) ? recent.sublist(0, maxCandidates) : recent;
      }
    }

    // Order by newest (date/ts) desc, then rank asc
    final moments = bestByKey.values.toList()
      ..sort((a, b) {
        final d = b.date.compareTo(a.date);
        if (d != 0) return d;
        final t = b.ts.compareTo(a.ts);
        if (t != 0) return t;
        return a.rank.compareTo(b.rank);
      });

    // Cap to a small list we will probe in _fetchLatest()
    return (moments.length > maxCandidates)
        ? moments.sublist(0, maxCandidates)
        : moments;
  }

  // Fallback: probe recent dates (today..N days back) under narrow prefixes to avoid
  // bucket-wide prefix quirks. Returns newest moments already ranked and sorted.
  Future<List<_Moment>> _findLatestCandidatesByRecentDates(
      Minio s3, String bucket, String device, {int daysBack = 7}) async {
    final dev = device.trim();
    final now = DateTime.now().toUtc();

    String fmtDate(DateTime dt) {
      String two(int x) => x.toString().padLeft(2, '0');
      return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}';
    }

    final Map<String, _Moment> bestByKey = {};

    void consider({required String date, required String ts, required int rank}) {
      if (!_isDate(date) || !_isTs(ts)) return;
      final key = '$date/$ts';
      final existing = bestByKey[key];
      final prefix = (rank == 0)
          ? '$dev/processed/$date/$ts/'
          : (rank == 2)
              ? '$dev/queued/$date/$ts/'
              : '$dev/$date/$ts/';
      if (existing == null || rank < existing.rank) {
        bestByKey[key] = _Moment(dev, date, ts, prefix, rank);
      }
    }

    Future<void> scanDate(String date) async {
      final roots = <(String,int)>[
        ('$dev/processed/$date/', 0),
        ('$dev/$date/',           1),
        ('$dev/queued/$date/',    2),
      ];
      for (final (root, rank) in roots) {
        await for (final obj in s3.listObjects(bucket, prefix: root, recursive: true)) {
          final k = _objKeyDyn(obj);
          if (k.isEmpty || k.endsWith('/')) continue;
          final rel = k.startsWith(root) ? k.substring(root.length) : k;
          final ts = rel.split('/').first;
          if (_isTs(ts)) consider(date: date, ts: ts, rank: rank);
        }
      }
    }

    for (int i = 0; i <= daysBack; i++) {
      final dt = now.subtract(Duration(days: i));
      await scanDate(fmtDate(dt));
    }

    final moments = bestByKey.values.toList()
      ..sort((a, b) {
        final d = b.date.compareTo(a.date);
        if (d != 0) return d;
        final t = b.ts.compareTo(a.ts);
        if (t != 0) return t;
        return a.rank.compareTo(b.rank);
      });

    debugPrint('[S3][datescan] found ${moments.length} moments in last ${daysBack + 1} day(s)');
    return moments;
  }

  Future<String?> _findLatestPrefixByScan(Minio s3, String bucket, String device) async {
    final root = '${device.trim()}/';

    String? bestDate;
    String? bestTs;
    String? bestPrefix;
    int bestRank = 99; // 0=processed, 1=direct, 2=queued

    void consider({required String date, required String ts, required int rank}) {
      if (!_isDate(date) || !_isTs(ts)) return;
      final isNewer = (bestDate == null)
          ? true
          : (date.compareTo(bestDate!) > 0) || (date == bestDate && ts.compareTo(bestTs ?? '') > 0);
      final sameMoment = (bestDate != null && date == bestDate && ts == bestTs);
      if (isNewer || (sameMoment && rank < bestRank)) {
        bestDate = date;
        bestTs = ts;
        bestRank = rank;
        if (rank == 0)      bestPrefix = '${root}processed/$date/$ts/';
        else if (rank == 2) bestPrefix = '${root}queued/$date/$ts/';
        else                bestPrefix = '${root}$date/$ts/';
      }
    }

    await for (final obj in s3.listObjects(bucket, prefix: root, recursive: true)) {
      final fullKey = _objKeyDyn(obj);
      if (fullKey.isEmpty || fullKey.endsWith('/')) continue;
      final rel = fullKey.startsWith(root) ? fullKey.substring(root.length) : fullKey;
      final parts = rel.split('/');
      if (parts.length < 3) continue;

      if (parts[0] == 'processed' && parts.length >= 4) {
        consider(date: parts[1], ts: parts[2], rank: 0);
      } else if (parts[0] == 'queued' && parts.length >= 4) {
        consider(date: parts[1], ts: parts[2], rank: 2);
      } else {
        consider(date: parts[0], ts: parts[1], rank: 1);
      }
    }

    if (bestPrefix != null) return bestPrefix;

    // bucket-wide fallback (handles weird prefixes AND IAM prefix filtering)
    // Iterate the whole bucket once, parse keys on the fly, and keep only the best moment.
    await for (final obj in s3.listObjects(bucket, recursive: true)) {
      var k = _objKeyDyn(obj);
      if (k.isEmpty || k.endsWith('/')) continue;

      // normalize
      k = k.trim();
      if (k.startsWith('/')) k = k.substring(1);

      // Match the device segment whether it's at the start or after any folder
      final devSeg = '${device.trim()}/';
      int ix;
      if (k.startsWith(devSeg)) {
        ix = 0; // device at beginning
      } else {
        ix = k.indexOf('/' + devSeg);
        if (ix >= 0) ix += 1; // move to the start of device segment
      }
      if (ix < 0) continue; // not this device

      // Portion after device id
      final after = k.substring(ix + devSeg.length);
      final parts = after.split('/');
      if (parts.length < 3) continue; // need at least date/ts/file

      String date = '';
      String ts   = '';
      int rank    = 1; // default: direct

      if (parts[0] == 'processed' && parts.length >= 4) {
        date = parts[1];
        ts   = parts[2];
        rank = 0;
      } else if (parts[0] == 'queued' && parts.length >= 4) {
        date = parts[1];
        ts   = parts[2];
        rank = 2;
      } else {
        date = parts[0];
        ts   = parts[1];
        rank = 1;
      }

      consider(date: date, ts: ts, rank: rank);
    }

    return bestPrefix;
  }

  Future<Map<String, dynamic>?> _safeDecodeJson(String txt) async {
    try {
      return txt.isNotEmpty
          ? Map<String, dynamic>.from(const JsonDecoder().convert(txt) as Map<String, dynamic>)
          : null;
    } catch (_) {
      return null;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).size.width < 420 ? 12.0 : 16.0;
    return Scaffold(
      appBar: AppBar(title: const Text('Fetch from S3')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(pad, 16, pad, 24),
        children: [
          _S3Form(
            bucketCtl: _bucketCtl,
            regionCtl: _regionCtl,
            deviceManualCtl: _deviceManualCtl,
            busy: _busy,
            devices: _devices,
            selectedDevice: _selectedDevice,
            loadingDevices: _loadingDevices,
            onRefreshDevices: _loadDevices,
            onDeviceChanged: (v) async {
              setState(() {
                _selectedDevice = v;
                _dates = [];
                _times = [];
                _selectedDate = null;
                _selectedTime = null;
              });
              // Date/time picker disabled — Fetch Latest always scans for newest.
            },
            onFetch: _fetchLatest,
            dates: _dates,
            times: _times,
            selectedDate: _selectedDate,
            selectedTime: _selectedTime,
            onDateChanged: (v) async {
              setState(() {
                _selectedDate = v;
                _times = [];
                _selectedTime = null;
              });
              final dev = (_deviceManualCtl.text.trim().isNotEmpty)
                  ? _deviceManualCtl.text.trim()
                  : (_selectedDevice ?? '');
              if (v != null && dev.isNotEmpty) {
                await _loadTimesForDate(dev, v);
              }
            },
            onTimeChanged: (v) => setState(() => _selectedTime = v),
            onRefreshDates: () async {
              _snack('Date/session picker disabled — Fetch Latest gets the newest automatically.');
            },
            hasCached: _lastArgs != null,
            onOpenCached: () { if (_lastArgs != null) pushSessionViewer(context, _lastArgs!); },
          ),
          if (_devices.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Tip: Bucket is fixed to "microheal". Tap refresh to load devices or type a device ID.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _S3Form extends StatefulWidget {
  const _S3Form({
    required this.bucketCtl,
    required this.regionCtl,
    required this.deviceManualCtl,
    required this.busy,
    required this.devices,
    required this.selectedDevice,
    required this.onRefreshDevices,
    required this.onDeviceChanged,
    required this.onFetch,
    required this.loadingDevices,
    required this.dates,
    required this.times,
    required this.selectedDate,
    required this.selectedTime,
    required this.onDateChanged,
    required this.onTimeChanged,
    required this.onRefreshDates,
    required this.hasCached,
    required this.onOpenCached,
  });

  final TextEditingController bucketCtl;
  final TextEditingController regionCtl;
  final TextEditingController deviceManualCtl;
  final bool busy;

  final List<String> devices;
  final String? selectedDevice;
  final VoidCallback onRefreshDevices;
  final ValueChanged<String?> onDeviceChanged;
  final VoidCallback onFetch;
  final bool loadingDevices;

  final List<String> dates;
  final List<String> times;
  final String? selectedDate;
  final String? selectedTime;
  final ValueChanged<String?> onDateChanged;
  final ValueChanged<String?> onTimeChanged;
  final VoidCallback onRefreshDates;

  final bool hasCached;
  final VoidCallback onOpenCached;

  @override
  State<_S3Form> createState() => _S3FormState();
}

class _S3FormState extends State<_S3Form> {
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('S3 Settings',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: widget.bucketCtl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Bucket',
                helperText: 'Forced to microheal for this build',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.regionCtl,
                    decoration: const InputDecoration(labelText: 'Region'),
                    textInputAction: TextInputAction.next,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Device'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: widget.selectedDevice,
                        items: widget.devices
                            .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                            .toList(),
                        onChanged: widget.onDeviceChanged,
                        hint: const Text('Select device'),
                        disabledHint: const Text('No devices'),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh devices',
                  onPressed: widget.loadingDevices ? null : widget.onRefreshDevices,
                  icon: widget.loadingDevices
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Date (optional)'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: widget.selectedDate,
                        items: widget.dates.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                        onChanged: widget.onDateChanged,
                        hint: const Text('YYYY-MM-DD'),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Session (optional)'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: widget.selectedTime,
                        items: widget.times.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                        onChanged: widget.onTimeChanged,
                        hint: const Text('YYYYMMDD_HHMMSS'),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh dates/sessions',
                  onPressed: widget.onRefreshDates,
                  icon: const Icon(Icons.event),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.deviceManualCtl,
              decoration: const InputDecoration(
                labelText: 'Device (manual)',
                hintText: 'e.g. 1f0298d885aa',
                helperText: 'If dropdown is empty, type device ID here',
              ),
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.busy ? null : widget.onFetch,
                    icon: const Icon(Icons.download),
                    label: Text(widget.busy ? 'Fetching…' : 'Fetch latest'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (widget.hasCached && !widget.busy) ? widget.onOpenCached : null,
                    icon: const Icon(Icons.history),
                    label: const Text('View last'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
