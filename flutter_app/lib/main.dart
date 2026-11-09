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
    const seed = Color(0xFF6C63FF);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Auto Subtitle Generator',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF10111A),
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1C29),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF202232),
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
      _serverOkay = false;
      _progress = 0.02;
      _stage = 'ভিডিও সার্ভারে আপলোড হচ্ছে...';
      _error = null;
      _jobId = null;
      _transcriptPreview = null;
      _detectedLanguage = null;
      _insights = null;
    });
    await _disposePreview();

    try {
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
      if (mounted) {
        setState(() {
          _error = _friendlyError(e);
          _stage = 'প্রসেসিং ব্যর্থ হয়েছে';
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

  Future<void> _saveSrt() => _saveExport('srt');

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

  Widget _exportButton(String label, String kind, IconData icon) =>
      OutlinedButton.icon(
        onPressed: _busy ? null : () => _saveExport(kind),
        icon: Icon(icon, size: 17),
        label: Text(label),
      );

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

  String _friendlyError(Object error) {
    var text = error.toString().replaceFirst('Exception: ', '').trim();
    if (text.contains('SocketException') || text.contains('Connection refused')) {
      return 'সার্ভারে সংযোগ নেই। Backend চালু আছে কি না এবং API URL ঠিক আছে কি না দেখো।';
    }
    if (text.length > 700) text = '${text.substring(0, 700)}...';
    return text;
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

  Widget _sectionTitle(String title, String subtitle) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Auto-Subtitle Generator', style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Server test',
            onPressed: _busy ? null : _checkServer,
            icon: Icon(Icons.wifi_tethering, color: _serverOkay ? Colors.greenAccent : null),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _buildHero(),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _sectionTitle('১. AI সার্ভার', 'Windows PC-তে Python backend চালু রাখো।'),
                      TextField(
                        controller: _serverController,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Backend URL',
                          hintText: 'http://192.168.0.105:8000',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(children: [
                        Icon(_serverOkay ? Icons.check_circle : Icons.info_outline,
                            color: _serverOkay ? Colors.greenAccent : Colors.amberAccent, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_serverStatusText, style: TextStyle(fontSize: 12, color: _serverOkay ? Colors.greenAccent : Colors.amberAccent))),
                        TextButton(onPressed: _busy ? null : _checkServer, child: const Text('Test')),
                      ]),
                      if (Platform.isAndroid)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'বাস্তব Android ফোনে 10.0.2.2 নয়—PC-এর Wi-Fi IPv4 address বসাও।',
                            style: TextStyle(fontSize: 11, color: Colors.amberAccent),
                          ),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _sectionTitle('২. ভিডিও নির্বাচন', 'MP4, MOV, MKV, WEBM, AVI ও M4V সমর্থিত।'),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickVideo,
                        icon: const Icon(Icons.video_library_outlined),
                        label: const Text('ভিডিও নির্বাচন করুন'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      ),
                      if (_selectedFile != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: const Color(0xFF24283A), borderRadius: BorderRadius.circular(12)),
                          child: Row(children: [
                            const Icon(Icons.movie_creation_outlined, color: Colors.lightBlueAccent),
                            const SizedBox(width: 10),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_selectedFile!.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(_formatSize(_selectedFileSize ?? 0), style: const TextStyle(color: Colors.white60, fontSize: 12)),
                            ])),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: _busy ? null : () => setState(() { _selectedFile = null; _selectedFileSize = null; }),
                              icon: const Icon(Icons.close),
                            ),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _sectionTitle('৩. Caption সেটিংস', 'ভাষা, AI মডেল ও ভিডিওর caption style বেছে নাও।'),
                      DropdownMenu<String>(
                        initialSelection: _language,
                        enableFilter: true,
                        enableSearch: true,
                        requestFocusOnTap: true,
                        expandedInsets: EdgeInsets.zero,
                        label: const Text('ভাষা — লিখে খুঁজুন'),
                        leadingIcon: const Icon(Icons.language),
                        dropdownMenuEntries: _availableLanguages
                            .map((item) => DropdownMenuEntry<String>(
                                  value: item['code']!,
                                  label: '${item['name']} (${item['code']})',
                                ))
                            .toList(),
                        onSelected: _busy ? null : (value) => setState(() => _language = value ?? 'auto'),
                      ),
                      const SizedBox(height: 12),
                      _dropdown<String>(
                        label: 'AI মডেল',
                        value: _model,
                        values: const [
                          DropdownMenuItem(value: 'tiny', child: Text('Tiny — দ্রুত, কম রিসোর্স')),
                          DropdownMenuItem(value: 'base', child: Text('Base — Recommended')),
                          DropdownMenuItem(value: 'small', child: Text('Small — ভালো মান, বেশি সময়')),
                        ],
                        onChanged: (value) => setState(() => _model = value ?? 'base'),
                      ),
                      const SizedBox(height: 8),
                      const Text('প্রথমবার নির্বাচিত AI মডেল ডাউনলোড হবে। ৮ GB RAM PC-তে Base দিয়ে শুরু করো।',
                          style: TextStyle(fontSize: 11, color: Colors.white60)),
                      const SizedBox(height: 12),
                      _dropdown<String>(
                        label: 'Caption style',
                        value: _style,
                        values: const [
                          DropdownMenuItem(value: 'hormozi', child: Text('Hormozi — Yellow word highlight')),
                          DropdownMenuItem(value: 'clean', child: Text('Clean — Cyan highlight')),
                          DropdownMenuItem(value: 'neon', child: Text('Neon — Purple highlight')),
                          DropdownMenuItem(value: 'creator', child: Text('Creator — Mint highlight')),
                          DropdownMenuItem(value: 'cinema', child: Text('Cinema — Blue highlight')),
                          DropdownMenuItem(value: 'minimal', child: Text('Minimal — White subtitle')),
                        ],
                        onChanged: (value) => setState(() => _style = value ?? 'hormozi'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _hotwordsController,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                          labelText: 'Creator Vocabulary Boost',
                          hintText: 'যেমন: Nazim, OpenAI, Flutter, QuickBooks',
                          prefixIcon: Icon(Icons.auto_fix_high),
                          helperText: 'নাম, brand, technical term বা কঠিন শব্দ comma দিয়ে লেখো।',
                        ),
                      ),
                      Row(children: [
                        Expanded(child: _dropdown<int>(
                          label: 'এক লাইনে শব্দ',
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
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _busy ? null : _createCaptions,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome),
                  label: Text(_busy ? 'AI কাজ করছে...' : 'AI Caption তৈরি করুন'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54), textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                if (_busy || _jobId != null || _error != null) ...[
                  const SizedBox(height: 14),
                  Card(child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(_stage, style: const TextStyle(fontWeight: FontWeight.w700))),
                        Text('${(_progress * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: _busy ? _progress : (_jobId != null && _error == null ? 1 : 0)),
                      if (_detectedLanguage != null) ...[
                        const SizedBox(height: 8),
                        Text('Detected language: $_detectedLanguage', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                      ],
                    ]),
                  )),
                ],
                if (_jobId != null && !_busy && _error == null) ...[
                  const SizedBox(height: 14),
                  Card(child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _sectionTitle('ভিডিও Preview', 'রঙিন word-by-word caption যাচাই করো।'),
                      if (_videoController != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            height: 310,
                            color: Colors.black,
                            alignment: Alignment.center,
                            child: Video(controller: _videoController!),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          IconButton.filledTonal(onPressed: () => _player?.play(), icon: const Icon(Icons.play_arrow)),
                          IconButton.filledTonal(onPressed: () => _player?.pause(), icon: const Icon(Icons.pause)),
                          const Spacer(),
                          TextButton.icon(onPressed: _saveSrt, icon: const Icon(Icons.subtitles), label: const Text('SRT')),
                          FilledButton.icon(onPressed: _saveVideo, icon: const Icon(Icons.download), label: const Text('ভিডিও Save')),
                        ]),
                      ] else ...[
                        const Text('ভিডিও তৈরি হয়েছে। Preview না খুললেও নিচের বাটন দিয়ে ফাইল সেভ করা যাবে।',
                            style: TextStyle(color: Colors.white70)),
                        const SizedBox(height: 10),
                        Row(children: [
                          TextButton.icon(onPressed: _saveSrt, icon: const Icon(Icons.subtitles), label: const Text('SRT')),
                          const Spacer(),
                          FilledButton.icon(onPressed: _saveVideo, icon: const Icon(Icons.download), label: const Text('ভিডিও Save')),
                        ]),
                      ],
                      const Text('Export Center', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        OutlinedButton.icon(onPressed: _editTranscript, icon: const Icon(Icons.edit_note), label: const Text('Edit Transcript')),
                        OutlinedButton.icon(onPressed: _translateSubtitles, icon: const Icon(Icons.translate), label: const Text('Offline Translate')),
                      ]),
                      const SizedBox(height: 12),
                      const Text('Subtitle formats', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _exportButton('SRT', 'srt', Icons.subtitles),
                        _exportButton('WebVTT', 'vtt', Icons.closed_caption),
                        _exportButton('ASS', 'ass', Icons.style),
                        _exportButton('SSA', 'ssa', Icons.text_fields),
                        _exportButton('YouTube SBV', 'sbv', Icons.video_file),
                      ]),
                      const SizedBox(height: 12),
                      const Text('Text, spreadsheet & document', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _exportButton('Excel XLSX', 'xlsx', Icons.table_chart),
                        _exportButton('Word DOCX', 'docx', Icons.description),
                        _exportButton('CSV', 'csv', Icons.grid_on),
                        _exportButton('TSV', 'tsv', Icons.view_week),
                        _exportButton('TXT', 'txt', Icons.notes),
                        _exportButton('Timed TXT', 'timecoded-txt', Icons.schedule),
                        _exportButton('Markdown', 'md', Icons.code),
                        _exportButton('HTML', 'html', Icons.web),
                        _exportButton('Project JSON', 'json', Icons.data_object),
                        _exportButton('Creator Report', 'insights', Icons.insights),
                        _exportButton('All Exports ZIP', 'all-exports', Icons.folder_zip),
                      ]),
                      if (_translationTarget != null) ...[
                        const SizedBox(height: 8),
                        Text('Translated to $_translationTarget', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w700)),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          OutlinedButton(onPressed: () => _saveExport('translated-srt'), child: const Text('Translated SRT')),
                          OutlinedButton(onPressed: () => _saveExport('translated-vtt'), child: const Text('Translated VTT')),
                          OutlinedButton(onPressed: () => _saveExport('bilingual-srt'), child: const Text('Bilingual SRT')),
                          OutlinedButton(onPressed: () => _saveExport('translation-json'), child: const Text('Translation JSON')),
                        ]),
                      ],
                      if (_insights != null) ...[
                        const Divider(height: 20),
                        const Text('Creator Pulse', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          _metricChip('Words', '${_insights!['word_count'] ?? 0}'),
                          _metricChip('Pace', '${_insights!['speaking_rate_wpm'] ?? 0} WPM'),
                          _metricChip('Long pauses', '${_insights!['pause_count_over_1_2s'] ?? 0}'),
                          _metricChip('Review words', '${(_insights!['low_alignment_probability_words'] as List<dynamic>? ?? const []).length}'),
                        ]),
                        const SizedBox(height: 10),
                        _buildInsightList('Review these words', _insights!['low_alignment_probability_words'], 'text', 'start'),
                        _buildInsightList('Possible hook moments', _insights!['hook_moment_suggestions'], 'text', 'start'),
                        const SizedBox(height: 8),
                        const Text('Creator suggestions are heuristic. Check the original audio before publishing.',
                            style: TextStyle(fontSize: 11, color: Colors.white54)),
                      ],
                      if (_transcriptPreview != null && _transcriptPreview!.isNotEmpty) ...[
                        const Divider(height: 20),
                        const Text('Transcript preview', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(_transcriptPreview!, maxLines: 5, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, height: 1.5)),
                      ],
                    ]),
                  )),
                ],
                const SizedBox(height: 20),
                const Center(child: Text('Local AI processing • Whisper + FFmpeg', style: TextStyle(color: Colors.white38, fontSize: 11))),
              ],
            ),
          ),
        ),
      ),
    );
  }

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

  Widget _buildHero() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [Color(0xFF302B63), Color(0xFF24243E), Color(0xFF0F0C29)]),
        ),
        child: Row(children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(17)),
            child: const Icon(Icons.closed_caption, size: 34, color: Colors.white),
          ),
          const SizedBox(width: 14),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Turn speech into captions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            SizedBox(height: 5),
            Text('Whisper-এর সব সমর্থিত ভাষা • Auto Detect • Burned-in MP4', style: TextStyle(fontSize: 12, color: Colors.white70)),
          ])),
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
