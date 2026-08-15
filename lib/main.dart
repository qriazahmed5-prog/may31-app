import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:typed_data';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
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
          : const MainChatScreen(),
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
        _navigateToChat();
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
    _navigateToChat();
  }

  void _navigateToChat() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const MainChatScreen()),
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

// ---------------- Main Chat & Presence Screen ----------------
class MainChatScreen extends StatefulWidget {
  const MainChatScreen({super.key});

  @override
  State<MainChatScreen> createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen> {
  final String currentUid = FirebaseAuth.instance.currentUser?.uid ?? "user_1";
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final TextEditingController _msgController = TextEditingController();

  RTCDataChannel? _dataChannel;
  RTCPeerConnection? _peerConnection;

  @override
  void initState() {
    super.initState();
    _setupPresence();
    _initWebRTC();
  }

  // Handle Online / Offline Presence
  void _setupPresence() {
    final userPresenceRef = _dbRef.child("presence/$currentUid");
    userPresenceRef.set({
      'status': 'online',
      'last_seen': ServerValue.timestamp,
    });
    userPresenceRef.onDisconnect().set({
      'status': 'offline',
      'last_seen': ServerValue.timestamp,
    });
  }

  // WebRTC Setup for P2P Files & Calls
  void _initWebRTC() async {
    Map<String, dynamic> configuration = {
      "iceServers": [
        {"urls": "stun:stun.l.google.com:19302"}
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    RTCDataChannelInit dataChannelDict = RTCDataChannelInit();
    _dataChannel = await _peerConnection!.createDataChannel("p2pDataChannel", dataChannelDict);

    _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
      debugPrint("Data Channel State: $state");
    };

    _dataChannel!.onMessage = (RTCDataChannelMessage data) {
      debugPrint("Received P2P Message/Media");
    };
  }

  // P2P Media Sender (Zero Cloud Storage)
  void _pickAndSendP2PFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.bytes != null) {
      Uint8List fileBytes = result.files.single.bytes!;
      String base64File = base64Encode(fileBytes);

      if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
        _dataChannel!.send(RTCDataChannelMessage(base64File));
      }
    }
  }

  // Send Message with Ticks logic
  void _sendMessage() {
    if (_msgController.text.trim().isNotEmpty) {
      _dbRef.child("messages").push().set({
        'sender': currentUid,
        'text': _msgController.text.trim(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'sent',
      });
      _msgController.clear();
    }
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('P2P Direct Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder(
              stream: _dbRef.child("messages").onValue,
              builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
                if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                  Map<dynamic, dynamic> map = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
                  List<dynamic> list = map.values.toList();
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      var item = list[index];
                      return ListTile(
                        title: Text(item['text'] ?? ''),
                        trailing: _buildTickIcon(item['status'] ?? 'sent'),
                      );
                    },
                  );
                }
                return const Center(child: Text('No Messages Yet'));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickAndSendP2PFile,
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
