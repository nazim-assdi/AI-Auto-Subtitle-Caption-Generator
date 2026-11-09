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
  bool _busy = false;
  bool _serverOkay = false;
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
  }

  @override
  void dispose() {
    _serverController.dispose();
    _player?.dispose();
    super.dispose();
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Future<void> _checkServer() async {
    try {
      final response = await http.get(_uri('/health')).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw Exception('সার্ভার উত্তর দেয়নি (${response.statusCode})');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final ready = data['ffmpeg_ready'] == true;
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
        _stage = ready
            ? 'সার্ভার সংযুক্ত • ${languageData['count'] ?? available.length - 1}টি ভাষা উপলব্ধ।'
            : 'সার্ভার চালু, কিন্তু FFmpeg পাওয়া যায়নি।';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverOkay = false;
        _stage = 'সার্ভারে সংযোগ হয়নি: ${_friendlyError(e)}';
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
    });
    await _disposePreview();

    try {
      final request = http.MultipartRequest('POST', _uri('/jobs'));
      request.fields['language'] = _language;
      request.fields['model_size'] = _model;
      request.fields['style'] = _style;
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

  Future<void> _saveSrt() async {
    final id = _jobId;
    if (id == null) return;
    try {
      final response = await http.get(_uri('/jobs/$id/download?kind=srt')).timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) throw Exception('SRT ফাইল পাওয়া যায়নি।');
      await FileSaver.instance.saveToDownloads(
        name: 'captions_${DateTime.now().millisecondsSinceEpoch}',
        bytes: response.bodyBytes,
        fileExtension: 'srt',
        mimeType: MimeType.text,
        subfolder: 'AI Captions',
      );
      if (mounted) setState(() => _stage = 'SRT সাবটাইটেল ফাইল সেভ হয়েছে।');
    } catch (e) {
      _showError('SRT সেভ করা যায়নি: ${_friendlyError(e)}');
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
                        Expanded(child: Text(_stage, style: const TextStyle(fontSize: 12, color: Colors.white70))),
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
                          DropdownMenuItem(value: 'hormozi', child: Text('Hormozi — White + Yellow highlight')),
                          DropdownMenuItem(value: 'clean', child: Text('Clean — White + Cyan highlight')),
                          DropdownMenuItem(value: 'neon', child: Text('Neon — White + Pink highlight')),
                        ],
                        onChanged: (value) => setState(() => _style = value ?? 'hormozi'),
                      ),
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
                if (_busy || _jobId != null) ...[
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
