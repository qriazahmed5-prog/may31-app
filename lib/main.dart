import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await [
    Permission.camera,
    Permission.microphone,
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

// ---------------- Users List Screen ----------------
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

  @override
  void initState() {
    super.initState();
    _listenForIncomingCalls();
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
      appBar: AppBar(title: const Text('Chats')),
      body: StreamBuilder(
        stream: dbRef.child('users').onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
            return const Center(child: Text('No users yet'));
          }
          Map<dynamic, dynamic> map =
              snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
          List<Map<dynamic, dynamic>> users = map.values
              .map((e) => e as Map<dynamic, dynamic>)
              .where((u) => u['uid'] != currentUid)
              .toList();

          if (users.isEmpty) {
            return const Center(child: Text('No other users yet'));
          }

          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              final user = users[index];
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
          );
        },
      ),
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

  @override
  void initState() {
    super.initState();
    List<String> ids = [currentUid, widget.peerUid];
    ids.sort();
    chatId = '${ids[0]}_${ids[1]}';
    _listenForNewMessages();
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

  void _sendMessage() {
    if (_msgController.text.trim().isNotEmpty) {
      _dbRef.child('chats').child(chatId).child('messages').push().set({
        'sender': currentUid,
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

  @override
  void dispose() {
    _notifPlayer.dispose();
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
                              Flexible(child: Text(item['text'] ?? '')),
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
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
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
