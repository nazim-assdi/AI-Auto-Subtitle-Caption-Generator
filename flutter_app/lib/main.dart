import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const CaptionApp());
}

class CaptionApp extends StatelessWidget {
  const CaptionApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF8277F7);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Auto Subtitle Generator',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0A1020),
        cardTheme: CardThemeData(
          color: const Color(0xFF151E30),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B2740),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: seed, width: 1.5),
          ),
        ),
      ),
      home: const CaptionHomePage(),
    );
  }
}

class CaptionHomePage extends StatefulWidget {
  const CaptionHomePage({super.key});

  @override
  State<CaptionHomePage> createState() => _CaptionHomePageState();
}

class _CaptionHomePageState extends State<CaptionHomePage> {
  late final TextEditingController _serverController;
  PlatformFile? _selectedFile;
  int? _selectedFileSize;
  String _language = 'auto';
  List<Map<String, String>> _availableLanguages = const [
    {'code': 'auto', 'name': 'Auto detect'},
  ];
  String _model = 'base';
  String _style = 'hormozi';
  String _position = 'bottom';
  int _wordsPerLine = 4;
  late final TextEditingController _hotwordsController;
  Map<String, dynamic>? _insights;
  String? _translationTarget;
  bool _busy = false;
  bool _serverOkay = false;
  String _serverStatusText = 'সার্ভার পরীক্ষা করা হয়নি। Test চাপো।';
  double _progress = 0;
  String _stage = 'প্রথমে PC-এর AI সার্ভার চালু করো।';
  String? _jobId;
  String? _error;
  String? _detectedLanguage;
  String? _transcriptPreview;
  Player? _player;
  VideoController? _videoController;
  int _activePage = 0;

  String get _baseUrl => _serverController.text.trim().replaceFirst(RegExp(r'/+$'), '');

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(
      text: Platform.isAndroid ? 'http://10.0.2.2:8000' : 'http://127.0.0.1:8000',
    );
    _hotwordsController = TextEditingController();
  }

  @override
  void dispose() {
    _serverController.dispose();
    _hotwordsController.dispose();
    _player?.dispose();
    super.dispose();
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Future<void> _checkServer() async {
    try {
      final response = await http.get(_uri('/health')).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw Exception('সার্ভার উত্তর দেয়নি (${response.statusCode})');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final ffmpegReady = data['ffmpeg_ready'] == true;
      final assReady = data['ass_filter_ready'] == true;
      final ready = ffmpegReady && assReady;
      final languageResponse = await http.get(_uri('/languages')).timeout(const Duration(seconds: 8));
      if (languageResponse.statusCode != 200) {
        throw Exception('সমর্থিত ভাষার তালিকা পাওয়া যায়নি (${languageResponse.statusCode})');
      }
      final languageData = _decodeJson(languageResponse.body);
      final rawLanguages = languageData['languages'] as List<dynamic>? ?? const [];
      final available = rawLanguages
          .whereType<Map<String, dynamic>>()
          .map((item) => <String, String>{
                'code': item['code']?.toString() ?? '',
                'name': item['name']?.toString() ?? item['code']?.toString() ?? '',
              })
          .where((item) => item['code']!.isNotEmpty)
          .toList();
      if (!available.any((item) => item['code'] == 'auto')) {
        available.insert(0, {'code': 'auto', 'name': 'Auto detect'});
      }
      if (!mounted) return;
      setState(() {
        _serverOkay = ready;
        _availableLanguages = available;
        if (!available.any((item) => item['code'] == _language)) _language = 'auto';
        _serverStatusText = !ffmpegReady
            ? 'FFmpeg/FFprobe পাওয়া যায়নি। install_backend নির্দেশনা দেখো।'
            : !assReady
                ? 'FFmpeg-এ ASS/libass subtitle filter নেই। Full FFmpeg build install করো।'
                : 'Server ready • ${languageData['count'] ?? available.length - 1}টি ভাষা উপলব্ধ।';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverOkay = false;
        _serverStatusText = 'সার্ভারে সংযোগ হয়নি: ${_friendlyError(e)}';
      });
    }
  }

  Future<void> _pickVideo() async {
    try {
      // file_picker 12+ provides pickFile() for a single selection.
      final file = await FilePicker.pickFile(type: FileType.video);
      if (file == null) return;
      if (file.path == null) {
        throw Exception('এই ভিডিওটির লোকাল path পাওয়া যায়নি। Files অ্যাপ থেকে আবার নির্বাচন করো।');
      }
      final selectedSize = file.lengthSync() ?? (await file.length()) ?? 0;
      if (!mounted) return;
      setState(() {
        _selectedFile = file;
        _selectedFileSize = selectedSize;
        _error = null;
        _jobId = null;
        _progress = 0;
        _transcriptPreview = null;
        _detectedLanguage = null;
        _stage = 'ভিডিও নির্বাচন করা হয়েছে।';
      });
      await _disposePreview();
    } catch (e) {
      _showError(_friendlyError(e));
    }
  }

  Future<void> _disposePreview() async {
    final old = _player;
    _player = null;
    _videoController = null;
    if (old != null) await old.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _createCaptions() async {
    final picked = _selectedFile;
    if (picked == null || picked.path == null) {
      _showError('আগে একটি ভিডিও নির্বাচন করো।');
      return;
    }
    if (_baseUrl.isEmpty || !(_baseUrl.startsWith('http://') || _baseUrl.startsWith('https://'))) {
      _showError('সঠিক API URL দাও। যেমন: http://192.168.0.105:8000');
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0.01;
      _stage = 'AI Backend সংযোগ পরীক্ষা হচ্ছে...';
      _error = null;
      _jobId = null;
      _transcriptPreview = null;
      _detectedLanguage = null;
      _insights = null;
    });
    await _disposePreview();

    try {
      // Never upload a large video until the local FastAPI server and FFmpeg are ready.
      final healthResponse = await http.get(_uri('/health')).timeout(const Duration(seconds: 10));
      if (healthResponse.statusCode != 200) {
        throw Exception('Backend health check ব্যর্থ হয়েছে (${healthResponse.statusCode})।');
      }
      final health = _decodeJson(healthResponse.body);
      if (health['ok'] != true) {
        throw Exception('Backend service প্রস্তুত নয়। start_backend.bat চালু আছে কি না দেখো।');
      }
      if (health['ffmpeg_ready'] != true) {
        throw Exception('FFmpeg অথবা FFprobe পাওয়া যায়নি। FFmpeg install করে নতুন Terminal থেকে start_backend.bat চালাও।');
      }
      if (health['ass_filter_ready'] != true) {
        throw Exception('FFmpeg-এ ASS/libass subtitle renderer পাওয়া যায়নি। Gyan Shared FFmpeg install করে Backend restart করো।');
      }
      if (!mounted) return;
      setState(() {
        _serverOkay = true;
        _serverStatusText = 'Server ready • FFmpeg ও subtitle renderer প্রস্তুত।';
        _progress = 0.02;
        _stage = 'ভিডিও সার্ভারে আপলোড হচ্ছে...';
      });
      final request = http.MultipartRequest('POST', _uri('/jobs'));
      request.fields['language'] = _language;
      request.fields['model_size'] = _model;
      request.fields['style'] = _style;
      request.fields['hotwords'] = _hotwordsController.text.trim();
      request.fields['words_per_line'] = _wordsPerLine.toString();
      request.fields['position'] = _position;
      request.files.add(await http.MultipartFile.fromPath('file', picked.path!, filename: picked.name));

      final streamed = await request.send().timeout(const Duration(hours: 4));
      final body = await streamed.stream.bytesToString();
      final data = _decodeJson(body);
      if (streamed.statusCode != 202) {
        throw Exception(_detailFrom(data, 'ভিডিও আপলোড করা যায়নি (${streamed.statusCode})'));
      }
      final id = data['job_id']?.toString();
      if (id == null || id.isEmpty) throw Exception('সার্ভার job ID দেয়নি।');
      if (mounted) setState(() => _jobId = id);
      await _pollJob(id);
    } catch (e) {
      final message = _friendlyError(e);
      final connectionFailure = _isConnectionFailure(e);
      if (mounted) {
        setState(() {
          if (connectionFailure) {
            _serverOkay = false;
            _serverStatusText = message;
          }
          _error = message;
          _progress = 0;
          _stage = connectionFailure ? 'Backend সংযোগ পাওয়া যায়নি' : 'প্রসেসিং ব্যর্থ হয়েছে';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _decodeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{'detail': body};
    }
  }

  String _detailFrom(Map<String, dynamic> data, String fallback) {
    final detail = data['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    return fallback;
  }

  Future<void> _pollJob(String id) async {
    while (mounted) {
      final response = await http.get(_uri('/jobs/$id')).timeout(const Duration(seconds: 30));
      final data = _decodeJson(response.body);
      if (response.statusCode != 200) {
        throw Exception(_detailFrom(data, 'Job status পাওয়া যায়নি (${response.statusCode})'));
      }
      final status = data['status']?.toString() ?? 'processing';
      final progress = (data['progress'] as num?)?.toDouble() ?? 0;
      if (mounted) {
        setState(() {
          _progress = progress.clamp(0, 100) / 100;
          _stage = data['stage']?.toString() ?? 'প্রসেসিং চলছে...';
          _detectedLanguage = data['detected_language']?.toString();
          _transcriptPreview = data['transcript_preview']?.toString();
        });
      }
      if (status == 'completed') {
        try {
          final insightsResponse = await http.get(_uri('/jobs/$id/insights')).timeout(const Duration(seconds: 30));
          if (insightsResponse.statusCode == 200 && mounted) {
            setState(() => _insights = _decodeJson(insightsResponse.body));
          }
        } catch (_) {}
        try {
          await _loadPreview(id);
        } catch (_) {
          // Preview is optional; the completed video can still be saved.
        }
        if (mounted) {
          setState(() {
            _progress = 1;
            _stage = _videoController != null
                ? 'সাবটাইটেলসহ ভিডিও তৈরি সম্পন্ন!'
                : 'ভিডিও তৈরি হয়েছে। Preview না খুললেও Save করা যাবে।';
          });
        }
        return;
      }
      if (status == 'failed') {
        throw Exception(data['error']?.toString() ?? 'AI প্রসেসিং ব্যর্থ হয়েছে।');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _loadPreview(String id) async {
    final player = Player();
    final controller = VideoController(player);
    try {
      await player.open(Media(_uri('/jobs/$id/stream').toString()), play: false);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _videoController = controller;
      });
    } catch (_) {
      await player.dispose();
      rethrow;
    }
  }

  Future<File> _downloadToTemp(String url, String extension) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(const Duration(hours: 3));
      if (response.statusCode != 200) throw Exception('ফাইল ডাউনলোড করা যায়নি (${response.statusCode})');
      final file = File('${Directory.systemTemp.path}/ai_caption_${DateTime.now().millisecondsSinceEpoch}.$extension');
      await response.pipe(file.openWrite());
      return file;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _saveVideo() async {
    final id = _jobId;
    if (id == null) return;
    File? tempFile;
    try {
      setState(() => _stage = 'ভিডিও সেভ করা হচ্ছে...');
      tempFile = await _downloadToTemp(_uri('/jobs/$id/download?kind=video').toString(), 'mp4');
      final name = 'AI_Captioned_${DateTime.now().millisecondsSinceEpoch}';
      if (Platform.isAndroid) {
        await FileSaver.instance.saveToGallery(
          name: name,
          file: tempFile,
          fileExtension: 'mp4',
          mimeType: MimeType.mp4Video,
          album: 'AI Captions',
        );
      } else {
        await FileSaver.instance.saveFile(
          name: name,
          file: tempFile,
          fileExtension: 'mp4',
          mimeType: MimeType.mp4Video,
        );
      }
      if (mounted) setState(() => _stage = 'ভিডিও সেভ করা হয়েছে।');
    } catch (e) {
      _showError('ভিডিও সেভ করা যায়নি: ${_friendlyError(e)}');
    } finally {
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _saveExport(String kind) async {
    final id = _jobId;
    if (id == null) return;
    try {
      final response = await http.get(_uri('/jobs/$id/download?kind=$kind')).timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) throw Exception('$kind ফাইল পাওয়া যায়নি।');
      await FileSaver.instance.saveToDownloads(
        name: '${kind}_${DateTime.now().millisecondsSinceEpoch}',
        bytes: response.bodyBytes,
        fileExtension: _exportExtension(kind),
        mimeType: _exportMimeType(kind),
        customMimeType: _exportCustomMimeType(kind),
        subfolder: 'AI Captions',
      );
      if (mounted) setState(() => _stage = '$kind export সেভ হয়েছে.');
    } catch (e) {
      _showError('$kind export সেভ করা যায়নি: ${_friendlyError(e)}');
    }
  }

  String _exportExtension(String kind) {
    const aliases = {
      'insights': 'json',
      'all-exports': 'zip',
      'json': 'json',
      'translation-json': 'json',
      'translated-srt': 'srt',
      'bilingual-srt': 'srt',
      'translated-vtt': 'vtt',
      'timecoded-txt': 'txt',
    };
    return aliases[kind] ?? kind;
  }

  MimeType _exportMimeType(String kind) {
    switch (kind) {
      case 'json':
      case 'insights':
      case 'translation-json':
        return MimeType.json;
      case 'xlsx':
        return MimeType.microsoftExcel;
      case 'docx':
        return MimeType.microsoftWord;
      case 'csv':
        return MimeType.csv;
      case 'md':
        return MimeType.markdown;
      case 'all-exports':
        return MimeType.zip;
      case 'txt':
      case 'timecoded-txt':
        return MimeType.text;
      default:
        return MimeType.custom;
    }
  }

  String? _exportCustomMimeType(String kind) {
    const types = {
      'srt': 'application/x-subrip',
      'translated-srt': 'application/x-subrip',
      'bilingual-srt': 'application/x-subrip',
      'vtt': 'text/vtt',
      'translated-vtt': 'text/vtt',
      'ass': 'text/plain',
      'ssa': 'text/plain',
      'sbv': 'text/plain',
      'tsv': 'text/tab-separated-values',
      'html': 'text/html',
    };
    return types[kind];
  }

  Future<void> _translateSubtitles() async {
    final id = _jobId;
    if (id == null || _busy) return;
    late http.Response optionsResponse;
    try {
      optionsResponse = await http.get(_uri('/jobs/$id/translation-options')).timeout(const Duration(seconds: 30));
    } catch (e) {
      _showError('Translation options পাওয়া যায়নি: ${_friendlyError(e)}');
      return;
    }
    if (!mounted) return;
    final options = _decodeJson(optionsResponse.body);
    final targetsRaw = options['targets'] as List<dynamic>? ?? const [];
    final targets = targetsRaw
        .whereType<Map<String, dynamic>>()
        .map((item) => <String, String>{
              'code': item['code']?.toString() ?? '',
              'name': item['name']?.toString() ?? item['code']?.toString() ?? '',
            })
        .where((item) => item['code']!.isNotEmpty)
        .toList();
    if (optionsResponse.statusCode != 200 || targets.isEmpty) {
      final sourceCode = options['source_language']?.toString() ?? _detectedLanguage ?? 'unknown';
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Offline translation model install করো'),
          content: Text('এই PC-তে $sourceCode থেকে অন্য ভাষায় যাওয়ার কোনো offline translation path পাওয়া যায়নি। Backend-এর install_translation_model.bat চালাও।\n\nউদাহরণ: install_translation_model.bat $sourceCode bn\n\nসব Whisper ভাষার translation model পাওয়া যায় না; install করার পর Server Test চাপো।'),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('ঠিক আছে'))],
        ),
      );
      return;
    }
    if (!mounted) return;
    var selected = targets.first['code']!;
    final target = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: const Text('Offline Subtitle Translation'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Source: ${options['source_language']}', style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Available target languages'),
              items: targets.map((item) => DropdownMenuItem(
                value: item['code'],
                child: Text('${item['name']} (${item['code']})'),
              )).toList(),
              onChanged: (value) => dialogSetState(() => selected = value ?? selected),
            ),
            const SizedBox(height: 8),
            const Text('শুধু install করা translation model দিয়ে কাজ হবে; video cloud-এ পাঠানো হবে না।',
                style: TextStyle(fontSize: 11, color: Colors.white60)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, selected), child: const Text('Translate')),
          ],
        ),
      ),
    );
    if (target == null) return;
    setState(() {
      _busy = true;
      _stage = 'Offline translation হচ্ছে...';
      _error = null;
    });
    try {
      final response = await http.post(
        _uri('/jobs/$id/translate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'target_language': target}),
      ).timeout(const Duration(hours: 2));
      final result = _decodeJson(response.body);
      if (response.statusCode != 201) {
        throw Exception(_detailFrom(result, 'Offline translation ব্যর্থ হয়েছে।'));
      }
      if (mounted) {
        setState(() {
          _translationTarget = target;
          _stage = 'Offline translation সম্পন্ন: ${options['source_language']} → $target';
        });
      }
    } catch (e) {
      _showError(_friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editTranscript() async {
    final id = _jobId;
    if (id == null || _busy) return;
    try {
      final response = await http.get(_uri('/jobs/$id/transcript')).timeout(const Duration(seconds: 30));
      final data = _decodeJson(response.body);
      if (response.statusCode != 200) {
        throw Exception(_detailFrom(data, 'Transcript পাওয়া যায়নি।'));
      }
      final segments = data['segments'] as List<dynamic>? ?? const [];
      final controller = TextEditingController(
        text: segments.map((item) => (item as Map<String, dynamic>)['text']?.toString() ?? '').join('\n'),
      );
      if (!mounted) {
        controller.dispose();
        return;
      }
      final edited = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Transcript Editor'),
          content: SizedBox(
            width: 620,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('প্রতিটি লাইনের text ঠিক করো। নতুন line যোগ/বাদ দিও না—প্রতিটি line-এর timing সংরক্ষিত থাকবে।',
                  style: TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(height: 12),
              Flexible(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 8,
                  maxLines: 18,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(hintText: 'প্রতি subtitle segment আলাদা লাইনে'),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('Save & Render')),
          ],
        ),
      );
      controller.dispose();
      if (edited == null) return;
      final texts = edited.split(RegExp(r'\r?\n'));
      setState(() {
        _busy = true;
        _progress = 0.76;
        _stage = 'Edited transcript পাঠানো হচ্ছে...';
        _error = null;
      });
      await _disposePreview();
      final update = await http.put(
        _uri('/jobs/$id/transcript'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'texts': texts,
          'style': _style,
          'words_per_line': _wordsPerLine,
          'position': _position,
        }),
      ).timeout(const Duration(minutes: 2));
      final updateData = _decodeJson(update.body);
      if (update.statusCode != 202) {
        throw Exception(_detailFrom(updateData, 'Transcript update ব্যর্থ হয়েছে।'));
      }
      await _pollJob(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _friendlyError(e);
          _stage = 'Transcript edit ব্যর্থ হয়েছে';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isConnectionFailure(Object error) {
    final value = error.toString().toLowerCase();
    return value.contains('socketexception') ||
        value.contains('connection refused') ||
        value.contains('errno = 1225') ||
        value.contains('failed host lookup') ||
        value.contains('connection timed out');
  }

  String _friendlyError(Object error) {
    var message = error.toString().replaceFirst('Exception: ', '').trim();
    if (_isConnectionFailure(error)) {
      return 'Backend চালু নেই অথবা এই URL/port-এ সংযোগ গ্রহণ করছে না: $_baseUrl'
          '\n\nWindows: repository-এর backend\\start_backend.bat চালাও এবং Terminal খোলা রাখো। প্রথমবার হলে আগে backend\\install_backend.bat চালাতে হবে। তারপর Test চাপো।'
          '\nAndroid: PC ও ফোন একই Wi-Fi-তে রাখো এবং Backend URL-এ PC-এর LAN IP দাও (যেমন http://192.168.0.105:8000)।';
    }
    if (message.length > 700) message = '${message.substring(0, 700)}...';
    return message;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1020),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 980;
            if (desktop) {
              return Row(children: [_buildSidebar(), Expanded(child: _buildWorkspace(desktop: true))]);
            }
            return Column(children: [
              Expanded(child: _buildWorkspace(desktop: false)),
              _buildBottomNavigation(),
            ]);
          },
        ),
      ),
    );
  }

  Widget _buildSidebar() => Container(
    width: 252,
    decoration: const BoxDecoration(color: Color(0xFF0D1628), border: Border(right: BorderSide(color: Color(0xFF202D43)))),
    padding: const EdgeInsets.fromLTRB(18, 22, 16, 18),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 42, height: 42, decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), gradient: const LinearGradient(colors: [Color(0xFF958BFF), Color(0xFF6355D9)])), child: const Icon(Icons.closed_caption_rounded, color: Colors.white, size: 25)),
        const SizedBox(width: 11),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('AI CREATOR', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
          Text('STUDIO', style: TextStyle(fontSize: 11, color: Color(0xFF9CA9C1), letterSpacing: 2.2)),
        ])),
      ]),
      const SizedBox(height: 34),
      const Padding(padding: EdgeInsets.only(left: 12, bottom: 10), child: Text('WORKSPACE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF71809A), letterSpacing: 1.5))),
      _buildSideNavItem(0, Icons.grid_view_rounded, 'Overview', 'Dashboard'),
      _buildSideNavItem(1, Icons.add_box_rounded, 'New project', 'Create captions'),
      _buildSideNavItem(2, Icons.file_download_rounded, 'Export center', 'Download files'),
      _buildSideNavItem(3, Icons.tune_rounded, 'Settings', 'Backend & defaults'),
      const Spacer(),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFF151F33), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF293850))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: _serverOkay ? const Color(0xFF48D6A0) : const Color(0xFFF2B85D), shape: BoxShape.circle)),
            const SizedBox(width: 8),
            const Text('AI ENGINE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
            const Spacer(),
            const Icon(Icons.memory_rounded, color: Colors.white54, size: 17),
          ]),
          const SizedBox(height: 9),
          Text(_serverOkay ? 'Connected & ready' : 'Waiting for backend', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _serverOkay ? const Color(0xFF65DDAE) : const Color(0xFFFFCB76))),
          const SizedBox(height: 4),
          Text(_serverOkay ? 'Whisper + FFmpeg online' : 'Start your local AI service', style: const TextStyle(fontSize: 10, color: Color(0xFF8D9AB1))),
          const SizedBox(height: 9),
          SizedBox(width: double.infinity, child: OutlinedButton(
            onPressed: _busy ? null : _checkServer,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Color(0xFF3A4964)), padding: const EdgeInsets.symmetric(vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Check connection', style: TextStyle(fontSize: 11)),
          )),
        ]),
      ),
      const SizedBox(height: 14),
      const Center(child: Text('CREATOR STUDIO  •  v1.0', style: TextStyle(color: Color(0xFF65738B), fontSize: 9, letterSpacing: 1))),
    ]),
  );

  Widget _buildSideNavItem(int index, IconData icon, String label, String subtitle) {
    final selected = _activePage == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected ? const Color(0xFF29264D) : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () => setState(() => _activePage = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Icon(icon, size: 19, color: selected ? const Color(0xFFB7AFFF) : const Color(0xFF8E9BB2)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: selected ? Colors.white : const Color(0xFFB5C0D2))),
                Text(subtitle, style: const TextStyle(fontSize: 9, color: Color(0xFF75839A))),
              ])),
              if (selected) Container(width: 5, height: 5, decoration: const BoxDecoration(color: Color(0xFF9D91FF), shape: BoxShape.circle)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavigation() => NavigationBar(
    height: 68,
    backgroundColor: const Color(0xFF0D1628),
    indicatorColor: const Color(0xFF302D59),
    selectedIndex: _activePage,
    onDestinationSelected: (index) => setState(() => _activePage = index),
    destinations: const [
      NavigationDestination(icon: Icon(Icons.grid_view_rounded), label: 'Home'),
      NavigationDestination(icon: Icon(Icons.add_box_rounded), label: 'Create'),
      NavigationDestination(icon: Icon(Icons.file_download_rounded), label: 'Exports'),
      NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Settings'),
    ],
  );

  String get _currentPageTitle => const ['Overview', 'New project', 'Export center', 'Settings'][_activePage];
  String get _currentPageSubtitle => const [
    'Your AI video workspace at a glance.',
    'Turn a video into polished, word-level captions.',
    'Download your video, subtitles and creator reports.',
    'Manage your local AI connection and defaults.',
  ][_activePage];

  Widget _buildWorkspace({required bool desktop}) => Column(children: [
    _buildTopBar(desktop: desktop),
    Expanded(child: IndexedStack(index: _activePage, children: [
      _buildDashboardPage(),
      _buildCreatePage(),
      _buildExportPage(),
      _buildSettingsPage(),
    ])),
  ]);

  Widget _buildTopBar({required bool desktop}) => Container(
    padding: EdgeInsets.fromLTRB(desktop ? 30 : 18, 17, desktop ? 30 : 18, 15),
    decoration: const BoxDecoration(color: Color(0xFF0A1020), border: Border(bottom: BorderSide(color: Color(0xFF1D2A40)))),
    child: Row(children: [
      if (!desktop) ...[
        Container(width: 34, height: 34, decoration: BoxDecoration(color: const Color(0xFF665BD2), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.closed_caption_rounded, color: Colors.white, size: 20)),
        const SizedBox(width: 10),
      ],
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_currentPageTitle, style: TextStyle(fontSize: desktop ? 21 : 17, fontWeight: FontWeight.w900, letterSpacing: -0.4)),
        if (desktop) Padding(padding: const EdgeInsets.only(top: 3), child: Text(_currentPageSubtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF8795AD)))),
      ])),
      _buildConnectionBadge(compact: !desktop),
      const SizedBox(width: 9),
      IconButton(
        tooltip: 'Refresh backend status',
        onPressed: _busy ? null : _checkServer,
        style: IconButton.styleFrom(backgroundColor: const Color(0xFF172238), foregroundColor: Colors.white70, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))),
        icon: const Icon(Icons.refresh_rounded, size: 19),
      ),
    ]),
  );

  Widget _buildConnectionBadge({bool compact = false}) => Container(
    padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12, vertical: 8),
    decoration: BoxDecoration(
      color: _serverOkay ? const Color(0xFF12352F) : const Color(0xFF382B20),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: _serverOkay ? const Color(0xFF286C59) : const Color(0xFF6C5130)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: _serverOkay ? const Color(0xFF5BE0AC) : const Color(0xFFFFC36A), shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(_serverOkay ? 'AI Online' : 'AI Offline', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _serverOkay ? const Color(0xFF79E2B8) : const Color(0xFFFFD08B))),
    ]),
  );

  Widget _pageFrame(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(constraints.maxWidth > 900 ? 30 : 17, 24, constraints.maxWidth > 900 ? 30 : 17, 34),
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1320), child: child)),
    ),
  );

  Widget _panel({required Widget child, EdgeInsets padding = const EdgeInsets.all(19)}) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: const Color(0xFF141E31),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF26364F)),
      boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 22, offset: Offset(0, 8))],
    ),
    child: child,
  );

  Widget _eyebrow(String value) => Text(value.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.45, color: Color(0xFF8F9DB5)));

  Widget _sectionHeading(String title, String subtitle, {Widget? trailing}) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: -0.2)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF8D9BB2), height: 1.4)),
      ])),
      ?trailing,
    ],
  );

  Widget _buildDashboardPage() => _pageFrame(
    LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > 820;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _eyebrow('Your creative workspace'),
            const SizedBox(height: 7),
            Text('Create something remarkable.', style: TextStyle(fontSize: wide ? 28 : 22, fontWeight: FontWeight.w900, letterSpacing: -0.9)),
            const SizedBox(height: 5),
            const Text('Everything you need to caption, polish and export your videos.', style: TextStyle(fontSize: 12, color: Color(0xFF8D9BB2))),
          ])),
          if (wide) FilledButton.icon(onPressed: _busy ? null : () => setState(() => _activePage = 1), icon: const Icon(Icons.add_rounded), label: const Text('New project'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF776BEB), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14))),
        ]),
        const SizedBox(height: 21),
        _buildDashboardHero(wide: wide),
        const SizedBox(height: 19),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _buildStatCard('Projects created', _jobId == null ? '0' : '1', Icons.movie_filter_rounded, const Color(0xFF9388FF), 'Local project history'),
          _buildStatCard('Languages', _availableLanguages.length > 1 ? '${_availableLanguages.length - 1}' : '100', Icons.language_rounded, const Color(0xFF54C9B0), 'Whisper recognition'),
          _buildStatCard('Export formats', '15+', Icons.file_download_outlined, const Color(0xFFF0B86B), 'Ready after rendering'),
          _buildStatCard('AI engine', _serverOkay ? 'Online' : 'Offline', Icons.memory_rounded, _serverOkay ? const Color(0xFF55D5A1) : const Color(0xFFF0B86B), 'Whisper + FFmpeg'),
        ]),
        const SizedBox(height: 19),
        if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: _buildRecentProjectPanel()),
          const SizedBox(width: 14),
          Expanded(flex: 5, child: _buildQuickActionsPanel()),
        ]) else Column(children: [
          _buildRecentProjectPanel(),
          const SizedBox(height: 13),
          _buildQuickActionsPanel(),
        ]),
        const SizedBox(height: 18),
        _buildWorkflowPanel(),
        const SizedBox(height: 15),
        const Center(child: Text('PRIVATE BY DESIGN  •  LOCAL AI PROCESSING', style: TextStyle(color: Color(0xFF62728C), fontSize: 9, letterSpacing: 1.2))),
      ]);
    }),
  );

  Widget _buildDashboardHero({required bool wide}) => Container(
    padding: EdgeInsets.all(wide ? 25 : 19),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF37336F), Color(0xFF29294F), Color(0xFF19263C)]),
      border: Border.all(color: const Color(0xFF514B91)),
    ),
    child: wide ? Row(children: [Expanded(child: _heroCopy()), const SizedBox(width: 20), _heroArtwork()]) : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_heroCopy(), const SizedBox(height: 15), _heroArtwork()]),
  );

  Widget _heroCopy() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(30)),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.auto_awesome_rounded, color: Color(0xFFE3DEFF), size: 14), SizedBox(width: 7), Text('AI-POWERED VIDEO WORKFLOW', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.1))]),
    ),
    const SizedBox(height: 14),
    const Text('Your words.\nYour style.\nReady to publish.', style: TextStyle(fontSize: 25, height: 1.15, fontWeight: FontWeight.w900, letterSpacing: -0.8)),
    const SizedBox(height: 10),
    const Text('Generate animated captions in 100 Whisper-supported languages, review your transcript and export in the formats you need.', style: TextStyle(fontSize: 11, height: 1.55, color: Color(0xFFD0D1EB))),
    const SizedBox(height: 17),
    FilledButton.icon(onPressed: _busy ? null : () => setState(() => _activePage = 1), icon: const Icon(Icons.play_arrow_rounded, size: 19), label: const Text('Start creating'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE7E4FF), foregroundColor: const Color(0xFF28254F), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12))),
  ]);

  Widget _heroArtwork() => Container(
    width: 190,
    height: 145,
    decoration: BoxDecoration(color: const Color(0x337E75EF), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0x557F77D9))),
    child: Stack(alignment: Alignment.center, children: [
      Container(width: 104, height: 104, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0x337E75EF), border: Border.all(color: const Color(0x667D75EA)))),
      Container(width: 72, height: 72, decoration: BoxDecoration(borderRadius: BorderRadius.circular(21), gradient: const LinearGradient(colors: [Color(0xFFA49AFF), Color(0xFF6558D5)]), boxShadow: const [BoxShadow(color: Color(0x665D54D3), blurRadius: 24)]), child: const Icon(Icons.closed_caption_rounded, color: Colors.white, size: 36)),
      Positioned(top: 22, left: 23, child: _floatingTag('WORD LEVEL', Icons.text_fields_rounded)),
      Positioned(bottom: 21, right: 13, child: _floatingTag('100 LANGS', Icons.language_rounded)),
    ]),
  );

  Widget _floatingTag(String text, IconData icon) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xFF1A2441), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF55518C))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 10, color: const Color(0xFFBEB7FF)), const SizedBox(width: 4), Text(text, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: 0.5))]),
  );

  Widget _buildStatCard(String label, String value, IconData icon, Color accent, String note) => SizedBox(
    width: 214,
    child: _panel(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Container(width: 34, height: 34, decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: accent, size: 18)), const Spacer(), const Icon(Icons.more_horiz_rounded, size: 17, color: Color(0xFF667690))]),
      const SizedBox(height: 14),
      Text(value, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
      const SizedBox(height: 3),
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(note, style: const TextStyle(fontSize: 9, color: Color(0xFF8492AA))),
    ])),
  );

  Widget _buildRecentProjectPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Recent project', 'Pick up where you left off.', trailing: TextButton(onPressed: () => setState(() => _activePage = 1), child: const Text('New project'))),
    const SizedBox(height: 15),
    if (_jobId == null) Container(
      padding: const EdgeInsets.symmetric(vertical: 23, horizontal: 15),
      decoration: BoxDecoration(color: const Color(0xFF10192B), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF293850))),
      child: Row(children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF25264D), borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.video_call_outlined, color: Color(0xFFB7AEFF))),
        const SizedBox(width: 12),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('No project yet', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)), SizedBox(height: 4), Text('Create your first captioned video to see it here.', style: TextStyle(fontSize: 10, color: Color(0xFF8795AD)))])),
      ]),
    ) else Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: const Color(0xFF10192B), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF293850))),
      child: Row(children: [
        Container(width: 46, height: 46, decoration: BoxDecoration(color: const Color(0xFF233A45), borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.movie_creation_rounded, color: Color(0xFF6DD7C1))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_selectedFile?.name ?? 'Captioned video project', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(_stage, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Color(0xFF93A2B9))),
        ])),
        const SizedBox(width: 8),
        IconButton.filledTonal(onPressed: () => setState(() => _activePage = 2), icon: const Icon(Icons.arrow_forward_rounded, size: 18)),
      ]),
    ),
  ]));

  Widget _buildQuickActionsPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Quick actions', 'Jump straight into your workflow.'),
    const SizedBox(height: 15),
    _quickActionRow(Icons.add_circle_outline_rounded, 'Create captions', 'Start a new video project', () => setState(() => _activePage = 1)),
    const SizedBox(height: 10),
    _quickActionRow(Icons.file_download_outlined, 'Open export center', 'Download your project files', () => setState(() => _activePage = 2)),
    const SizedBox(height: 10),
    _quickActionRow(Icons.settings_outlined, 'Connection settings', 'Configure your local AI backend', () => setState(() => _activePage = 3)),
  ]));

  Widget _quickActionRow(IconData icon, String title, String subtitle, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
      decoration: BoxDecoration(color: const Color(0xFF10192B), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, color: const Color(0xFFB4ABFF), size: 19),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)), Text(subtitle, style: const TextStyle(fontSize: 9, color: Color(0xFF8492AA)))])),
        const Icon(Icons.chevron_right_rounded, color: Color(0xFF8492AA), size: 18),
      ]),
    ),
  );

  Widget _buildWorkflowPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('A simple creator workflow', 'From raw footage to publish-ready assets.'),
    const SizedBox(height: 17),
    Wrap(spacing: 12, runSpacing: 12, children: [
      _workflowStep('01', 'Upload video', 'Choose MP4, MOV, MKV and more.', Icons.video_file_rounded),
      _workflowStep('02', 'Generate captions', 'Let Whisper find every word.', Icons.auto_awesome_rounded),
      _workflowStep('03', 'Review & polish', 'Edit text, style and timing.', Icons.edit_note_rounded),
      _workflowStep('04', 'Export & publish', 'Download files for your platforms.', Icons.rocket_launch_rounded),
    ]),
  ]));

  Widget _workflowStep(String number, String title, String description, IconData icon) => SizedBox(
    width: 220,
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 35, height: 35, decoration: BoxDecoration(color: const Color(0xFF27254C), borderRadius: BorderRadius.circular(10)), child: Center(child: Text(number, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFFC1B9FF))))),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 17, color: const Color(0xFF9A90FF)),
        const SizedBox(height: 6),
        Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(description, style: const TextStyle(fontSize: 9, color: Color(0xFF8492AA), height: 1.4)),
      ])),
    ]),
  );

  Widget _buildCreatePage() => _pageFrame(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('New video project', 'Choose your source footage, then configure AI captions before rendering.'),
    const SizedBox(height: 17),
    LayoutBuilder(builder: (context, constraints) {
      final twoColumns = constraints.maxWidth > 880;
      final source = _buildVideoSourcePanel();
      final settings = _buildCaptionSettingsPanel();
      if (twoColumns) return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: source), const SizedBox(width: 14), Expanded(child: settings)]);
      return Column(children: [source, const SizedBox(height: 14), settings]);
    }),
    const SizedBox(height: 15),
    if (_busy || _jobId != null || _error != null) _buildProcessingPanel(),
    const SizedBox(height: 3),
    Row(children: [
      const Icon(Icons.lock_outline_rounded, size: 14, color: Color(0xFF6F809A)),
      const SizedBox(width: 7),
      const Expanded(child: Text('Your local video is processed by your configured AI backend.', style: TextStyle(fontSize: 10, color: Color(0xFF7C8BA3)))),
      if (_jobId != null && !_busy && _error == null) FilledButton.icon(onPressed: () => setState(() => _activePage = 2), icon: const Icon(Icons.file_download_outlined, size: 17), label: const Text('Go to exports')),
    ]),
  ]));

  Widget _buildVideoSourcePanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('01  •  Source video', 'Select the footage you want to caption.'),
    const SizedBox(height: 14),
    InkWell(
      onTap: _busy ? null : _pickVideo,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 25),
        decoration: BoxDecoration(color: const Color(0xFF10192B), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF3B4771), width: 1.2)),
        child: Column(children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: const Color(0xFF28264E), borderRadius: BorderRadius.circular(15)), child: const Icon(Icons.cloud_upload_rounded, color: Color(0xFFC3BBFF), size: 25)),
          const SizedBox(height: 11),
          Text(_selectedFile == null ? 'Choose a video file' : 'Replace selected video', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          const Text('MP4  •  MOV  •  MKV  •  WEBM  •  AVI  •  M4V', textAlign: TextAlign.center, style: TextStyle(fontSize: 9, color: Color(0xFF8492AA), letterSpacing: 0.5)),
          const SizedBox(height: 10),
          const Text('Browse files', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFBDB5FF))),
        ]),
      ),
    ),
    if (_selectedFile != null) ...[
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF1C2C40), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF304B60))),
        child: Row(children: [
          const Icon(Icons.movie_creation_rounded, color: Color(0xFF6DD7C1), size: 20),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_selectedFile!.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11)), const SizedBox(height: 3), Text(_formatSize(_selectedFileSize ?? 0), style: const TextStyle(color: Color(0xFF8EA0B8), fontSize: 10))])),
          IconButton(onPressed: _busy ? null : () => setState(() { _selectedFile = null; _selectedFileSize = null; }), icon: const Icon(Icons.close_rounded, size: 18), tooltip: 'Remove video'),
        ]),
      ),
    ],
  ]));

  Widget _buildCaptionSettingsPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('02  •  Caption settings', 'Fine-tune language detection and visual style.'),
    const SizedBox(height: 14),
    DropdownMenu<String>(
      initialSelection: _language,
      enableFilter: true,
      enableSearch: true,
      requestFocusOnTap: true,
      expandedInsets: EdgeInsets.zero,
      label: const Text('Language'),
      leadingIcon: const Icon(Icons.language_rounded),
      dropdownMenuEntries: _availableLanguages.map((item) => DropdownMenuEntry<String>(value: item['code']!, label: '${item['name']} (${item['code']})')).toList(),
      onSelected: _busy ? null : (value) => setState(() => _language = value ?? 'auto'),
    ),
    const SizedBox(height: 12),
    _dropdown<String>(label: 'Whisper model', value: _model, values: const [
      DropdownMenuItem(value: 'tiny', child: Text('Tiny  •  Fastest')),
      DropdownMenuItem(value: 'base', child: Text('Base  •  Recommended')),
      DropdownMenuItem(value: 'small', child: Text('Small  •  Higher accuracy')),
    ], onChanged: (value) => setState(() => _model = value ?? 'base')),
    const SizedBox(height: 12),
    _dropdown<String>(label: 'Caption theme', value: _style, values: const [
      DropdownMenuItem(value: 'hormozi', child: Text('Hormozi  •  Yellow word highlight')),
      DropdownMenuItem(value: 'clean', child: Text('Clean  •  Cyan highlight')),
      DropdownMenuItem(value: 'neon', child: Text('Neon  •  Purple highlight')),
      DropdownMenuItem(value: 'creator', child: Text('Creator  •  Mint highlight')),
      DropdownMenuItem(value: 'cinema', child: Text('Cinema  •  Blue highlight')),
      DropdownMenuItem(value: 'minimal', child: Text('Minimal  •  White subtitle')),
    ], onChanged: (value) => setState(() => _style = value ?? 'hormozi')),
    const SizedBox(height: 12),
    TextField(controller: _hotwordsController, enabled: !_busy, maxLength: 1000, decoration: const InputDecoration(
      labelText: 'Creator vocabulary boost',
      hintText: 'Names, brands, technical words',
      prefixIcon: Icon(Icons.auto_fix_high_rounded),
      helperText: 'Optional hints for names and uncommon words.',
      counterText: '',
    )),
    const SizedBox(height: 12),
    Row(children: [
      Expanded(child: _dropdown<int>(
        label: 'Words per line',
        value: _wordsPerLine,
        values: List.generate(7, (i) => DropdownMenuItem(value: i + 2, child: Text('${i + 2} words'))),
        onChanged: (value) => setState(() => _wordsPerLine = value ?? 4),
      )),
      const SizedBox(width: 10),
      Expanded(child: _dropdown<String>(
        label: 'Caption position',
        value: _position,
        values: const [
          DropdownMenuItem(value: 'bottom', child: Text('Bottom safe zone')),
          DropdownMenuItem(value: 'top', child: Text('Top safe zone')),
          DropdownMenuItem(value: 'middle', child: Text('Middle')),
        ],
        onChanged: (value) => setState(() => _position = value ?? 'bottom'),
      )),
    ]),
    const SizedBox(height: 14),
    SizedBox(width: double.infinity, child: FilledButton.icon(
      onPressed: _busy ? null : _createCaptions,
      icon: _busy ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.auto_awesome_rounded, size: 18),
      label: Text(_busy ? 'Generating captions...' : 'Generate AI captions'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: const Color(0xFF766BE7), foregroundColor: Colors.white, textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    )),
  ]));

  Widget _buildProcessingPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Container(width: 35, height: 35, decoration: BoxDecoration(color: const Color(0xFF28264E), borderRadius: BorderRadius.circular(11)), child: const Icon(Icons.memory_rounded, color: Color(0xFFBDB5FF), size: 18)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Render status', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900)), Text(_stage, style: const TextStyle(fontSize: 10, color: Color(0xFF92A1B9)), maxLines: 2, overflow: TextOverflow.ellipsis)])),
      Text('${(_progress * 100).round()}%', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFFC3BBFF))),
    ]),
    const SizedBox(height: 14),
    ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(minHeight: 8, value: _busy ? _progress : (_jobId != null && _error == null ? 1 : 0), backgroundColor: const Color(0xFF28354C), color: _error != null ? const Color(0xFFE77783) : const Color(0xFF7B70ED))),
    if (_detectedLanguage != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text('Detected language: $_detectedLanguage', style: const TextStyle(fontSize: 10, color: Color(0xFF8E9DB4)))),
    if (_error != null) ...[
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: const Color(0xFF3B202C), borderRadius: BorderRadius.circular(11), border: Border.all(color: const Color(0xFF693747))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFFF8997), size: 18),
          const SizedBox(width: 9),
          Expanded(child: Text(_error!, style: const TextStyle(fontSize: 11, color: Color(0xFFFFB4BE), height: 1.5))),
        ]),
      ),
    ],
    if (_jobId != null && !_busy && _error == null) ...[
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerRight, child: FilledButton.tonalIcon(onPressed: () => setState(() => _activePage = 2), icon: const Icon(Icons.file_download_outlined, size: 17), label: const Text('Open export center'))),
    ],
  ]));

  Widget _buildExportPage() => _pageFrame(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Export center', 'All your finished assets, organised and ready to download.'),
    const SizedBox(height: 17),
    if (_jobId == null || _error != null) _panel(child: Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 12), child: Column(children: [
      Container(width: 58, height: 58, decoration: BoxDecoration(color: const Color(0xFF26254D), borderRadius: BorderRadius.circular(18)), child: const Icon(Icons.inventory_2_outlined, color: Color(0xFFB8AEFF), size: 27)),
      const SizedBox(height: 13),
      const Text('Your export library is empty', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      const Text('Create a captioned video first. Your downloads will appear here.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Color(0xFF8D9BB2))),
      const SizedBox(height: 15),
      FilledButton.icon(onPressed: () => setState(() => _activePage = 1), icon: const Icon(Icons.add_rounded), label: const Text('Create a project')),
    ]))))
    else LayoutBuilder(builder: (context, constraints) {
      final twoColumns = constraints.maxWidth > 960;
      final preview = _buildPreviewPanel();
      final downloads = _buildDownloadsPanel();
      if (twoColumns) return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 6, child: Column(children: [preview, const SizedBox(height: 14), _buildCreatorPulsePanel()])), const SizedBox(width: 15), Expanded(flex: 5, child: downloads)]);
      return Column(children: [preview, const SizedBox(height: 14), downloads, const SizedBox(height: 14), _buildCreatorPulsePanel()]);
    }),
  ]));

  Widget _buildPreviewPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Video preview', 'Review your rendered captions before publishing.'),
    const SizedBox(height: 13),
    if (_videoController != null) ClipRRect(borderRadius: BorderRadius.circular(13), child: Container(height: 300, width: double.infinity, color: Colors.black, alignment: Alignment.center, child: Video(controller: _videoController!)))
    else Container(width: double.infinity, height: 150, decoration: BoxDecoration(color: const Color(0xFF10192B), borderRadius: BorderRadius.circular(13)), child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.movie_creation_outlined, color: Color(0xFF8796B1), size: 31), SizedBox(height: 8), Text('Preview unavailable', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11)), Text('You can still download the rendered video.', style: TextStyle(color: Color(0xFF7F8EA6), fontSize: 9))])),
    const SizedBox(height: 11),
    Row(children: [
      if (_videoController != null) ...[IconButton.filledTonal(onPressed: () => _player?.play(), icon: const Icon(Icons.play_arrow_rounded)), const SizedBox(width: 5), IconButton.filledTonal(onPressed: () => _player?.pause(), icon: const Icon(Icons.pause_rounded))],
      const Spacer(),
      FilledButton.icon(onPressed: _busy ? null : _saveVideo, icon: const Icon(Icons.download_rounded, size: 17), label: const Text('Download MP4'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF766BE7))),
    ]),
    if (_detectedLanguage != null) Padding(padding: const EdgeInsets.only(top: 9), child: Text('Detected language: $_detectedLanguage', style: const TextStyle(fontSize: 10, color: Color(0xFF90A0BA)))),
    if (_transcriptPreview != null && _transcriptPreview!.isNotEmpty) ...[
      const Divider(height: 22, color: Color(0xFF2B3A52)),
      const Text('Transcript preview', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
      const SizedBox(height: 7),
      Text(_transcriptPreview!, maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFAAB6C9), height: 1.5, fontSize: 10)),
      Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _editTranscript, icon: const Icon(Icons.edit_note, size: 17), label: const Text('Edit transcript'))),
    ],
  ]));

  Widget _buildDownloadsPanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Download files', 'Choose a format or take everything in one bundle.', trailing: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF1F3B36), borderRadius: BorderRadius.circular(20)), child: const Text('READY', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Color(0xFF7AE1B8), letterSpacing: 1)))),
    const SizedBox(height: 14),
    _exportGroup('SUBTITLE FORMATS', [
      _exportTile('SRT subtitle', 'Universal subtitle file', Icons.subtitles_rounded, 'srt'),
      _exportTile('WebVTT', 'Web video captions', Icons.closed_caption_rounded, 'vtt'),
      _exportTile('ASS / SSA', 'Styled subtitle formats', Icons.style_rounded, 'ass'),
      _exportTile('YouTube SBV', 'YouTube caption format', Icons.video_file_rounded, 'sbv'),
    ]),
    const SizedBox(height: 17),
    _exportGroup('DOCUMENTS & DATA', [
      _exportTile('Excel workbook', 'Captions, word timing & insights', Icons.table_chart_rounded, 'xlsx'),
      _exportTile('Word document', 'Formatted transcript table', Icons.description_rounded, 'docx'),
      _exportTile('CSV spreadsheet', 'Comma-separated data', Icons.grid_on_rounded, 'csv'),
      _exportTile('TSV spreadsheet', 'Tab-separated data', Icons.view_week_rounded, 'tsv'),
      _exportTile('Plain text', 'Transcript without styling', Icons.notes_rounded, 'txt'),
      _exportTile('Timecoded text', 'Text with timestamps', Icons.schedule_rounded, 'timecoded-txt'),
      _exportTile('Markdown / HTML', 'Portable formatted transcript', Icons.code_rounded, 'md'),
      _exportTile('Project JSON', 'Structured transcript data', Icons.data_object_rounded, 'json'),
      _exportTile('Creator report', 'Creator Pulse metrics', Icons.insights_rounded, 'insights'),
    ]),
    const SizedBox(height: 17),
    Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF302D62), Color(0xFF202B45)]), borderRadius: BorderRadius.circular(13), border: Border.all(color: const Color(0xFF4A4587))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.folder_zip_rounded, color: Color(0xFFC5BBFF), size: 20), const SizedBox(width: 9), const Expanded(child: Text('Complete export bundle', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900))), const Text('ZIP', style: TextStyle(fontSize: 9, color: Color(0xFFD4CEFF), fontWeight: FontWeight.w900))]),
        const SizedBox(height: 5),
        const Text('All subtitle, spreadsheet, document and text files in one download.', style: TextStyle(fontSize: 10, color: Color(0xFFC5C5E0), height: 1.4)),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: () => _saveExport('all-exports'), icon: const Icon(Icons.download_rounded, size: 16), label: const Text('Download all exports'))),
      ]),
    ),
    if (_translationTarget != null) ...[
      const SizedBox(height: 16),
      _exportGroup('TRANSLATED CAPTIONS  •  $_translationTarget', [
        _exportTile('Translated SRT', 'Translated subtitle file', Icons.translate_rounded, 'translated-srt'),
        _exportTile('Translated VTT', 'Translated WebVTT', Icons.closed_caption_rounded, 'translated-vtt'),
        _exportTile('Bilingual SRT', 'Original + translated captions', Icons.language_rounded, 'bilingual-srt'),
        _exportTile('Translation JSON', 'Translated segment data', Icons.data_object_rounded, 'translation-json'),
      ]),
    ],
    const SizedBox(height: 14),
    OutlinedButton.icon(onPressed: _translateSubtitles, icon: const Icon(Icons.translate_rounded), label: const Text('Translate subtitles offline')),
  ]));

  Widget _exportGroup(String title, List<Widget> items) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _eyebrow(title),
    const SizedBox(height: 8),
    ...items,
  ]);

  Widget _exportTile(String title, String subtitle, IconData icon, String kind) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Material(
      color: const Color(0xFF10192B),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: _busy ? null : () => _saveExport(kind),
        borderRadius: BorderRadius.circular(11),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10), child: Row(children: [
          Icon(icon, size: 17, color: const Color(0xFFB5ACFF)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)), const SizedBox(height: 2), Text(subtitle, style: const TextStyle(fontSize: 9, color: Color(0xFF8796AD)))])),
          const Icon(Icons.download_outlined, size: 16, color: Color(0xFF8E9BB2)),
        ])),
      ),
    ),
  );

  Widget _buildCreatorPulsePanel() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Creator Pulse', 'A quick read on your video and transcript.'),
    const SizedBox(height: 12),
    if (_insights == null) const Text('Creator insights will appear when rendering is complete.', style: TextStyle(color: Color(0xFF8D9BB2), fontSize: 10))
    else ...[
      Wrap(spacing: 8, runSpacing: 8, children: [
        _metricChip('Words', '${_insights!['word_count'] ?? 0}'),
        _metricChip('Pace', '${_insights!['speaking_rate_wpm'] ?? 0} WPM'),
        _metricChip('Long pauses', '${_insights!['pause_count_over_1_2s'] ?? 0}'),
        _metricChip('Review words', '${(_insights!['low_alignment_probability_words'] as List<dynamic>? ?? const []).length}'),
      ]),
      const SizedBox(height: 10),
      _buildInsightList('Review these words', _insights!['low_alignment_probability_words'], 'text', 'start'),
      _buildInsightList('Possible hook moments', _insights!['hook_moment_suggestions'], 'text', 'start'),
      const SizedBox(height: 7),
      const Text('Suggestions are heuristic. Check the original audio before publishing.', style: TextStyle(fontSize: 9, color: Color(0xFF8190A8))),
    ],
  ]));

  Widget _buildSettingsPage() => _pageFrame(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _sectionHeading('Workspace settings', 'Configure the local processing service and runtime preferences.'),
    const SizedBox(height: 17),
    _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 38, height: 38, decoration: BoxDecoration(color: const Color(0xFF25264D), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.dns_rounded, color: Color(0xFFB9B0FF))),
        const SizedBox(width: 11),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('AI backend connection', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900)), Text('Local FastAPI service • Whisper • FFmpeg', style: TextStyle(fontSize: 10, color: Color(0xFF8796AD)))])),
        _buildConnectionBadge(),
      ]),
      const SizedBox(height: 18),
      TextField(controller: _serverController, enabled: !_busy, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Backend URL', hintText: 'http://127.0.0.1:8000', prefixIcon: Icon(Icons.link_rounded), helperText: 'Windows: 127.0.0.1. Android: use the PC Wi-Fi IPv4 address.')),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Text(_serverStatusText, style: TextStyle(fontSize: 10, color: _serverOkay ? const Color(0xFF70DDB2) : const Color(0xFFFFCC83), height: 1.4))),
        const SizedBox(width: 12),
        FilledButton.icon(onPressed: _busy ? null : _checkServer, icon: const Icon(Icons.wifi_tethering_rounded, size: 17), label: const Text('Test connection')),
      ]),
      if (Platform.isAndroid) const Padding(padding: EdgeInsets.only(top: 9), child: Text('Physical Android device: connect to the same Wi-Fi as your PC, then enter the PC LAN IP. 10.0.2.2 only applies to Android emulators.', style: TextStyle(fontSize: 10, color: Color(0xFFFFCC83), height: 1.4))),
    ])),
    const SizedBox(height: 14),
    LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth > 700;
      final cards = [
        _settingsInfoCard(Icons.language_rounded, 'Language engine', '100 Whisper-supported recognition languages with Auto Detect.'),
        _settingsInfoCard(Icons.memory_rounded, 'Model profiles', 'Tiny for speed, Base for balanced results, Small for higher accuracy.'),
        _settingsInfoCard(Icons.security_rounded, 'Local processing', 'Your selected video is sent only to the backend URL configured above.'),
      ];
      if (wide) return Row(crossAxisAlignment: CrossAxisAlignment.start, children: cards.map((card) => Expanded(child: Padding(padding: const EdgeInsets.only(right: 10), child: card))).toList());
      return Column(children: cards.map((card) => Padding(padding: const EdgeInsets.only(bottom: 10), child: card)).toList());
    }),
    const SizedBox(height: 10),
    _panel(padding: const EdgeInsets.all(15), child: Row(children: [
      const Icon(Icons.info_outline_rounded, color: Color(0xFF8D9BB2), size: 19),
      const SizedBox(width: 10),
      const Expanded(child: Text('Creator Studio connects to a local AI backend. Keep the backend available while creating and exporting a project.', style: TextStyle(color: Color(0xFF8D9BB2), fontSize: 10, height: 1.5))),
      TextButton(onPressed: () => setState(() => _activePage = 0), child: const Text('Overview')),
    ])),
  ]));

  Widget _settingsInfoCard(IconData icon, String title, String detail) => _panel(
    padding: const EdgeInsets.all(15),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: const Color(0xFFAFA6FF), size: 21),
      const SizedBox(height: 10),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
      const SizedBox(height: 5),
      Text(detail, style: const TextStyle(color: Color(0xFF8796AD), fontSize: 9, height: 1.5)),
    ]),
  );

  Widget _buildInsightList(String title, dynamic rawItems, String textKey, String timeKey) {
    final items = rawItems is List ? rawItems.whereType<Map<String, dynamic>>().toList() : <Map<String, dynamic>>[];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        ...items.take(6).map((item) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item[timeKey] ?? 0}s  ', style: const TextStyle(color: Colors.amberAccent, fontSize: 11)),
            Expanded(child: Text(item[textKey]?.toString() ?? '', style: const TextStyle(color: Colors.white70, fontSize: 12))),
          ]),
        )),
      ]),
    );
  }

  Widget _metricChip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xFF262A3A), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10)),
        ]),
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> values,
    required ValueChanged<T?> onChanged,
  }) => DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: values,
        onChanged: _busy ? null : onChanged,
      );
}
