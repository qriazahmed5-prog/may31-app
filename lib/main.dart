import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await [
    Permission.camera,
    Permission.microphone,
    Permission.contacts,
  ].request();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P Media Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: FirebaseAuth.instance.currentUser == null
          ? const PhoneAuthScreen()
          : const UsersListScreen(),
    );
  }
}

// ---------------- Phone Auth Screen ----------------
class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  String _verificationId = '';
  bool _codeSent = false;

  void _verifyPhone() async {
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: _phoneController.text.trim(),
      verificationCompleted: (PhoneAuthCredential credential) async {
        await FirebaseAuth.instance.signInWithCredential(credential);
        _saveUserAndGo();
      },
      verificationFailed: (FirebaseAuthException e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Verification Failed')),
        );
      },
      codeSent: (String verificationId, int? resendToken) {
        setState(() {
          _verificationId = verificationId;
          _codeSent = true;
        });
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _verificationId = verificationId;
      },
    );
  }

  void _signInWithOTP() async {
    PhoneAuthCredential credential = PhoneAuthProvider.credential(
      verificationId: _verificationId,
      smsCode: _otpController.text.trim(),
    );
    await FirebaseAuth.instance.signInWithCredential(credential);
    _saveUserAndGo();
  }

  void _saveUserAndGo() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final phone = FirebaseAuth.instance.currentUser!.phoneNumber ?? '';
    final dbRef = FirebaseDatabase.instance.ref();
    await dbRef.child('users').child(uid).set({
      'uid': uid,
      'phone': phone,
    });
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const UsersListScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phone Login')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (!_codeSent) ...[
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone Number (+92...)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _verifyPhone,
                child: const Text('Send OTP'),
              ),
            ] else ...[
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Enter 6-Digit OTP',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _signInWithOTP,
                child: const Text('Verify & Login'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------- Users List Screen (Contact-based) ----------------
class UsersListScreen extends StatefulWidget {
  const UsersListScreen({super.key});

  @override
  State<UsersListScreen> createState() => _UsersListScreenState();
}

class _UsersListScreenState extends State<UsersListScreen> {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final dbRef = FirebaseDatabase.instance.ref();
  final AudioPlayer _ringPlayer = AudioPlayer();
  bool _isRinging = false;

  bool _loading = true;
  Set<String> _myContactNumbers = {};
  List<Map<dynamic, dynamic>> _matchedUsers = [];

  @override
  void initState() {
    super.initState();
    _listenForIncomingCalls();
    _loadContactsAndUsers();
  }

  // Normalize phone number: keep only digits, take last 10 (to ignore country code differences)
  String _normalize(String number) {
    String digits = number.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 10) {
      digits = digits.substring(digits.length - 10);
    }
    return digits;
  }

  Future<void> _loadContactsAndUsers() async {
    bool granted = await FlutterContacts.requestPermission();
    if (!granted) {
      setState(() => _loading = false);
      return;
    }

    List<Contact> contacts =
        await FlutterContacts.getContacts(withProperties: true);

    Set<String> contactNumbers = {};
    for (var c in contacts) {
      for (var p in c.phones) {
        contactNumbers.add(_normalize(p.number));
      }
    }
    _myContactNumbers = contactNumbers;

    final snapshot = await dbRef.child('users').get();
    if (!snapshot.exists || snapshot.value == null) {
      setState(() => _loading = false);
      return;
    }

    Map<dynamic, dynamic> map = snapshot.value as Map<dynamic, dynamic>;
    List<Map<dynamic, dynamic>> matched = [];
    for (var entry in map.values) {
      final user = entry as Map<dynamic, dynamic>;
      if (user['uid'] == currentUid) continue;
      final userPhone = user['phone'] ?? '';
      final normalizedUserPhone = _normalize(userPhone);
      if (_myContactNumbers.contains(normalizedUserPhone)) {
        matched.add(user);
      }
    }

    if (mounted) {
      setState(() {
        _matchedUsers = matched;
        _loading = false;
      });
    }
  }

  void _listenForIncomingCalls() {
    dbRef.child('calls').onChildAdded.listen((event) async {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;
      if (data['calleeId'] == currentUid && data['status'] == 'ringing') {
        final callId = event.snapshot.key!;

        _isRinging = true;
        await _ringPlayer.setReleaseMode(ReleaseMode.loop);
        await _ringPlayer.play(AssetSource('sounds/nokia.mp3'));

        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CallScreen(
                callId: callId,
                peerUid: data['callerId'],
                isVideo: data['isVideo'] ?? false,
                isCaller: false,
              ),
            ),
          ).then((_) => _stopRingtone());
        }
      }
    });
  }

  void _stopRingtone() async {
    if (_isRinging) {
      await _ringPlayer.stop();
      _isRinging = false;
    }
  }

  @override
  void dispose() {
    _ringPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _loading = true);
              _loadContactsAndUsers();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _matchedUsers.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Text(
                      'None of your phone contacts are using this app yet.\nInvite them to chat here!',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _matchedUsers.length,
                  itemBuilder: (context, index) {
                    final user = _matchedUsers[index];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(user['phone'] ?? 'Unknown'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatScreen(
                              peerUid: user['uid'],
                              peerName: user['phone'] ?? 'Unknown',
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

// ---------------- Voice Message Bubble Widget ----------------
class VoiceMessageBubble extends StatefulWidget {
  final String filePath;
  const VoiceMessageBubble({super.key, required this.filePath});

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  void _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      await _player.play(DeviceFileSource(widget.filePath));
      setState(() => _isPlaying = true);
    }
  }

  String _fmt(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    return '${twoDigits(d.inMinutes)}:${twoDigits(d.inSeconds % 60)}';
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle,
              size: 32, color: Colors.teal),
          onPressed: _togglePlay,
        ),
        Text(
          _duration.inMilliseconds > 0
              ? '${_fmt(_position)} / ${_fmt(_duration)}'
              : 'Voice message',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

// ---------------- Private Chat Screen ----------------
class ChatScreen extends StatefulWidget {
  final String peerUid;
  final String peerName;
  const ChatScreen({super.key, required this.peerUid, required this.peerName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final String currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final TextEditingController _msgController = TextEditingController();
  final AudioPlayer _notifPlayer = AudioPlayer();
  late String chatId;
  int _lastMessageCount = 0;

  // ---- File sharing (P2P + chunking) ----
  RTCPeerConnection? _fileConn;
  RTCDataChannel? _fileChannel;
  bool _fileChannelReady = false;
  final Map<String, List<Uint8List?>> _recvChunks = {};
  final Map<String, Map<String, dynamic>> _recvMeta = {};
  final Map<String, String> _localFilePaths = {};

  // ---- Voice recording ----
  final Record _audioRecorder = Record();
  bool _isRecording = false;
  String? _recordingPath;

  @override
  void initState() {
    super.initState();
    List<String> ids = [currentUid, widget.peerUid];
    ids.sort();
    chatId = '${ids[0]}_${ids[1]}';
    _listenForNewMessages();
    _setupFileChannel();
  }

  void _listenForNewMessages() {
    _dbRef.child('chats').child(chatId).child('messages').onValue.listen((event) {
      if (event.snapshot.value == null) return;
      Map<dynamic, dynamic> map = event.snapshot.value as Map<dynamic, dynamic>;
      int count = map.length;
      if (_lastMessageCount != 0 && count > _lastMessageCount) {
        List<dynamic> list = map.values.toList();
        list.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
        var lastMsg = list.last;
        if (lastMsg['sender'] != currentUid) {
          _notifPlayer.play(AssetSource('sounds/iphone.mp3'));
        }
      }
      _lastMessageCount = count;
    });
  }

  // -------- P2P Data Channel Setup for File Transfer --------
  void _setupFileChannel() async {
    _fileConn = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    });

    final signalRef = _dbRef.child('fileSignal').child(chatId);
    bool isInitiator = currentUid.compareTo(widget.peerUid) < 0;

    _fileConn!.onIceCandidate = (RTCIceCandidate candidate) {
      final path = isInitiator ? 'callerCandidates' : 'calleeCandidates';
      signalRef.child(path).push().set(candidate.toMap());
    };

    if (isInitiator) {
      await signalRef.remove();

      _fileChannel = await _fileConn!.createDataChannel(
        'fileChannel',
        RTCDataChannelInit()..ordered = true,
      );
      _fileChannel!.onMessage = _handleDataChannelMessage;
      _fileChannel!.onDataChannelState = (state) {
        setState(() {
          _fileChannelReady = state == RTCDataChannelState.RTCDataChannelOpen;
        });
      };

      RTCSessionDescription offer = await _fileConn!.createOffer();
      await _fileConn!.setLocalDescription(offer);
      await signalRef.child('offer').set({'sdp': offer.sdp, 'type': offer.type});

      signalRef.child('answer').onValue.listen((event) async {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null && _fileConn!.getRemoteDescription() == null) {
          await _fileConn!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
        }
      });

      signalRef.child('calleeCandidates').onChildAdded.listen((event) {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null) {
          _fileConn!.addCandidate(RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          ));
        }
      });
    } else {
      _fileConn!.onDataChannel = (RTCDataChannel channel) {
        _fileChannel = channel;
        _fileChannel!.onMessage = _handleDataChannelMessage;
        _fileChannel!.onDataChannelState = (state) {
          setState(() {
            _fileChannelReady = state == RTCDataChannelState.RTCDataChannelOpen;
          });
        };
      };

      signalRef.child('offer').onValue.listen((event) async {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null && _fileConn!.getRemoteDescription() == null) {
          await _fileConn!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
          RTCSessionDescription answer = await _fileConn!.createAnswer();
          await _fileConn!.setLocalDescription(answer);
          await signalRef.child('answer').set({'sdp': answer.sdp, 'type': answer.type});
        }
      });

      signalRef.child('callerCandidates').onChildAdded.listen((event) {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null) {
          _fileConn!.addCandidate(RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          ));
        }
      });
    }
  }

  // -------- Receiving chunks --------
  void _handleDataChannelMessage(RTCDataChannelMessage message) async {
    if (message.isBinary) return;
    final data = jsonDecode(message.text);

    if (data['t'] == 'meta') {
      final id = data['id'];
      _recvMeta[id] = data;
      _recvChunks[id] = List<Uint8List?>.filled(data['total'], null);
    } else if (data['t'] == 'chunk') {
      final id = data['id'];
      final i = data['i'];
      final bytes = base64Decode(data['d']);
      if (_recvChunks[id] == null) return;
      _recvChunks[id]![i] = bytes;

      bool complete = _recvChunks[id]!.every((e) => e != null);
      if (complete) {
        final meta = _recvMeta[id]!;
        final builder = BytesBuilder();
        for (var c in _recvChunks[id]!) {
          builder.add(c!);
        }
        final finalBytes = builder.toBytes();
        final dir = await getApplicationDocumentsDirectory();
        final localFile = File('${dir.path}/${meta['name']}');
        await localFile.writeAsBytes(finalBytes);

        if (mounted) {
          setState(() {
            _localFilePaths[id] = localFile.path;
          });
        }
        _recvChunks.remove(id);
        _recvMeta.remove(id);
      }
    }
  }

  // -------- Sending files with chunking --------
  Future<void> _sendFileBytes(Uint8List bytes, String fileName, String mime) async {
    if (_fileChannel == null ||
        _fileChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Peer is not connected right now. Ask them to open this chat.'),
        ),
      );
      return;
    }

    String fileId = DateTime.now().millisecondsSinceEpoch.toString();
    const chunkSize = 16000;
    int total = (bytes.length / chunkSize).ceil();
    String kind = mime.startsWith('image/')
        ? 'image'
        : mime.startsWith('video/')
            ? 'video'
            : mime.startsWith('audio/')
                ? 'voice'
                : 'file';

    _fileChannel!.send(RTCDataChannelMessage(jsonEncode({
      't': 'meta',
      'id': fileId,
      'name': fileName,
      'size': bytes.length,
      'mime': mime,
      'total': total,
    })));

    for (int i = 0; i < total; i++) {
      int start = i * chunkSize;
      int end = (start + chunkSize > bytes.length) ? bytes.length : start + chunkSize;
      Uint8List chunk = bytes.sublist(start, end);
      String b64 = base64Encode(chunk);

      _fileChannel!.send(RTCDataChannelMessage(jsonEncode({
        't': 'chunk',
        'id': fileId,
        'i': i,
        'd': b64,
      })));

      await Future.delayed(const Duration(milliseconds: 5));
    }

    final dir = await getApplicationDocumentsDirectory();
    final localFile = File('${dir.path}/$fileName');
    await localFile.writeAsBytes(bytes);
    if (mounted) {
      setState(() {
        _localFilePaths[fileId] = localFile.path;
      });
    }

    _dbRef.child('chats').child(chatId).child('messages').push().set({
      'sender': currentUid,
      'type': kind,
      'fileId': fileId,
      'fileName': fileName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'status': 'sent',
    });
  }

  String _guessMime(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return 'image/$ext';
    if (['mp4', 'mov', 'mkv', 'avi'].contains(ext)) return 'video/$ext';
    return 'application/octet-stream';
  }

  void _pickImageOrVideo() async {
    final picker = ImagePicker();
    final XFile? picked = await showModalBottomSheet<XFile?>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Photo from Gallery'),
              onTap: () async {
                final f = await picker.pickImage(source: ImageSource.gallery);
                if (mounted) Navigator.pop(context, f);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Video from Gallery'),
              onTap: () async {
                final f = await picker.pickVideo(source: ImageSource.gallery);
                if (mounted) Navigator.pop(context, f);
              },
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final mime = _guessMime(picked.name);
    await _sendFileBytes(bytes, picked.name, mime);
  }

  void _pickAnyFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.single.bytes == null) return;
    final bytes = result.files.single.bytes!;
    final fileName = result.files.single.name;
    final mime = _guessMime(fileName);
    await _sendFileBytes(bytes, fileName, mime);
  }

  void _showAttachOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Photo / Video'),
              onTap: () {
                Navigator.pop(context);
                _pickImageOrVideo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('Document / Any File'),
              onTap: () {
                Navigator.pop(context);
                _pickAnyFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  // -------- Voice recording --------
  void _startRecording() async {
    bool hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission denied')),
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(path: path, encoder: AudioEncoder.aacLc);
    setState(() {
      _isRecording = true;
      _recordingPath = path;
    });
  }

  void _stopAndSendRecording() async {
    final path = await _audioRecorder.stop();
    setState(() => _isRecording = false);
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _sendFileBytes(bytes, fileName, 'audio/m4a');
  }

  void _cancelRecording() async {
    await _audioRecorder.stop();
    setState(() => _isRecording = false);
  }

  void _sendMessage() {
    if (_msgController.text.trim().isNotEmpty) {
      _dbRef.child('chats').child(chatId).child('messages').push().set({
        'sender': currentUid,
        'type': 'text',
        'text': _msgController.text.trim(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'sent',
      });
      _msgController.clear();
    }
  }

  void _startCall(bool isVideo) async {
    final callRef = _dbRef.child('calls').push();
    await callRef.set({
      'callerId': currentUid,
      'calleeId': widget.peerUid,
      'isVideo': isVideo,
      'status': 'ringing',
    });
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CallScreen(
          callId: callRef.key!,
          peerUid: widget.peerUid,
          isVideo: isVideo,
          isCaller: true,
        ),
      ),
    );
  }

  Widget _buildTickIcon(String status) {
    if (status == 'seen') {
      return const Icon(Icons.done_all, size: 16, color: Colors.blue);
    } else if (status == 'delivered') {
      return const Icon(Icons.done_all, size: 16, color: Colors.grey);
    } else {
      return const Icon(Icons.check, size: 16, color: Colors.grey);
    }
  }

  Widget _buildMessageContent(Map item) {
    String type = item['type'] ?? 'text';
    if (type == 'text') {
      return Text(item['text'] ?? '');
    }

    String? localPath = _localFilePaths[item['fileId']];

    if (type == 'voice') {
      if (localPath == null) {
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic, size: 20),
            SizedBox(width: 4),
            Text('Voice message (receiving...)'),
          ],
        );
      }
      return VoiceMessageBubble(filePath: localPath);
    }

    if (type == 'image') {
      if (localPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(File(localPath), width: 180, fit: BoxFit.cover),
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image, size: 20),
          const SizedBox(width: 4),
          Flexible(
            child: Text(item['fileName'] ?? 'Image (receiving...)',
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }

    IconData icon = type == 'video' ? Icons.videocam : Icons.insert_drive_file;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(localPath != null ? icon : Icons.hourglass_bottom, size: 20),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            localPath != null
                ? (item['fileName'] ?? 'File')
                : '${item['fileName'] ?? 'File'} (receiving...)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _notifPlayer.dispose();
    _fileChannel?.close();
    _fileConn?.close();
    _audioRecorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peerName),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () => _startCall(false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () => _startCall(true),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_fileChannelReady)
            Container(
              width: double.infinity,
              color: Colors.orange.shade100,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: const Text(
                'Connecting for file sharing...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
          Expanded(
            child: StreamBuilder(
              stream: _dbRef.child('chats').child(chatId).child('messages').onValue,
              builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
                if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                  Map<dynamic, dynamic> map =
                      snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
                  List<dynamic> list = map.values.toList();
                  list.sort((a, b) =>
                      (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      var item = list[index];
                      bool isMe = item['sender'] == currentUid;
                      return Align(
                        alignment:
                            isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isMe
                                ? Colors.teal.shade100
                                : Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(child: _buildMessageContent(item)),
                              if (isMe) ...[
                                const SizedBox(width: 4),
                                _buildTickIcon(item['status'] ?? 'sent'),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  );
                }
                return const Center(child: Text('Say Hi 👋'));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _showAttachOptions,
                ),
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_msgController.text.trim().isEmpty)
                  GestureDetector(
                    onLongPress: _startRecording,
                    onLongPressUp: _stopAndSendRecording,
                    child: IconButton(
                      icon: Icon(
                        _isRecording ? Icons.mic : Icons.mic_none,
                        color: _isRecording ? Colors.red : null,
                      ),
                      onPressed: () {},
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
          if (_isRecording)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
                  const SizedBox(width: 6),
                  const Text('Recording... release mic to send'),
                  TextButton(
                    onPressed: _cancelRecording,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- Call Screen (Audio + Video) ----------------
class CallScreen extends StatefulWidget {
  final String callId;
  final String peerUid;
  final bool isVideo;
  final bool isCaller;

  const CallScreen({
    super.key,
    required this.callId,
    required this.peerUid,
    required this.isVideo,
    required this.isCaller,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  final AudioPlayer _outgoingRingPlayer = AudioPlayer();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  String _status = 'Connecting...';

  final Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]
  };

  @override
  void initState() {
    super.initState();
    _setup();
    if (widget.isCaller) {
      _outgoingRingPlayer.setReleaseMode(ReleaseMode.loop);
      _outgoingRingPlayer.play(AssetSource('sounds/nokia.mp3'));
    }
  }

  Future<void> _setup() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': widget.isVideo ? {'facingMode': 'user'} : false,
    });
    _localRenderer.srcObject = _localStream;

    _peerConnection = await createPeerConnection(_config);

    for (var track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams[0];
        _outgoingRingPlayer.stop();
        setState(() => _status = 'Connected');
      }
    };

    final callRef = _dbRef.child('calls').child(widget.callId);

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      final path = widget.isCaller ? 'callerCandidates' : 'calleeCandidates';
      callRef.child(path).push().set(candidate.toMap());
    };

    if (widget.isCaller) {
      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      await callRef.child('offer').set({
        'sdp': offer.sdp,
        'type': offer.type,
      });

      callRef.child('answer').onValue.listen((event) async {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null && _peerConnection!.getRemoteDescription() == null) {
          RTCSessionDescription answer =
              RTCSessionDescription(data['sdp'], data['type']);
          await _peerConnection!.setRemoteDescription(answer);
        }
      });

      callRef.child('calleeCandidates').onChildAdded.listen((event) {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null) {
          _peerConnection!.addCandidate(RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          ));
        }
      });
    } else {
      callRef.child('offer').onValue.listen((event) async {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null && _peerConnection!.getRemoteDescription() == null) {
          RTCSessionDescription offer =
              RTCSessionDescription(data['sdp'], data['type']);
          await _peerConnection!.setRemoteDescription(offer);

          RTCSessionDescription answer = await _peerConnection!.createAnswer();
          await _peerConnection!.setLocalDescription(answer);
          await callRef.child('answer').set({
            'sdp': answer.sdp,
            'type': answer.type,
          });
        }
      });

      callRef.child('callerCandidates').onChildAdded.listen((event) {
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data != null) {
          _peerConnection!.addCandidate(RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          ));
        }
      });
    }

    await callRef.child('status').set('active');
  }

  void _endCall() async {
    await _outgoingRingPlayer.stop();
    await _dbRef.child('calls').child(widget.callId).remove();
    _localStream?.getTracks().forEach((track) => track.stop());
    await _peerConnection?.close();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _outgoingRingPlayer.dispose();
    _localStream?.getTracks().forEach((track) => track.stop());
    _peerConnection?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (widget.isVideo)
            Positioned.fill(
              child: RTCVideoView(_remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            )
          else
            Center(
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
          if (widget.isVideo)
            Positioned(
              top: 40,
              right: 20,
              width: 100,
              height: 150,
              child: RTCVideoView(_localRenderer, mirror: true),
            ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                backgroundColor: Colors.red,
                onPressed: _endCall,
                child: const Icon(Icons.call_end),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
