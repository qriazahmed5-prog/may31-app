import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:video_player/video_player.dart';

// ---------------- Theme Notifier ----------------
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

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
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'P2P Media Chat',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: FirebaseAuth.instance.currentUser == null
              ? const PhoneAuthScreen()
              : const HomeScreen(),
        );
      },
    );
  }
}

// ---------------- Shared Helper Functions ----------------
String normalizePhone(String number) {
  String digits = number.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length > 10) {
    digits = digits.substring(digits.length - 10);
  }
  return digits;
}

String generateInviteCode() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final rnd = Random();
  return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
}

Future<List<Map<String, dynamic>>> getMatchedAppUsers(String currentUid) async {
  bool granted = await FlutterContacts.requestPermission();
  if (!granted) return [];

  List<Contact> contacts = await FlutterContacts.getContacts(withProperties: true);
  Set<String> contactNumbers = {};
  for (var c in contacts) {
    for (var p in c.phones) {
      contactNumbers.add(normalizePhone(p.number));
    }
  }

  final dbRef = FirebaseDatabase.instance.ref();
  final snapshot = await dbRef.child('users').get();
  List<Map<String, dynamic>> matched = [];

  if (snapshot.exists && snapshot.value != null) {
    Map<dynamic, dynamic> map = snapshot.value as Map<dynamic, dynamic>;
    for (var entry in map.values) {
      final user = entry as Map<dynamic, dynamic>;
      if (user['uid'] == currentUid) continue;
      final userPhone = user['phone'] ?? '';
      if (contactNumbers.contains(normalizePhone(userPhone))) {
        matched.add({
          'uid': user['uid'],
          'phone': user['phone'] ?? 'Unknown',
          'photo': user['photo'],
        });
      }
    }
  }
  return matched;
}

Future<bool> isUserBlocked(String myUid, String otherUid) async {
  final dbRef = FirebaseDatabase.instance.ref();
  final snap = await dbRef.child('users').child(myUid).child('blocked').child(otherUid).get();
  return snap.exists && snap.value == true;
}

Widget avatarWidget(String? photoBase64, {double radius = 20, IconData fallback = Icons.person}) {
  if (photoBase64 != null && photoBase64.isNotEmpty) {
    try {
      return CircleAvatar(
        radius: radius,
        backgroundImage: MemoryImage(base64Decode(photoBase64)),
      );
    } catch (_) {}
  }
  return CircleAvatar(radius: radius, child: Icon(fallback));
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
    await dbRef.child('users').child(uid).child('uid').set(uid);
    await dbRef.child('users').child(uid).child('phone').set(phone);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const HomeScreen()),
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

// ---------------- Home Screen (Tabs: Chats / Groups) ----------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final dbRef = FirebaseDatabase.instance.ref();
  final AudioPlayer _ringPlayer = AudioPlayer();
  bool _isRinging = false;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _listenForIncomingCalls();
  }

  void _listenForIncomingCalls() {
    dbRef.child('calls').onChildAdded.listen((event) async {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;
      if (data['calleeId'] == currentUid && data['status'] == 'ringing') {
        final callerId = data['callerId'];
        final blocked = await isUserBlocked(currentUid, callerId);
        if (blocked) return;

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
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('P2P Media Chat'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Chats', icon: Icon(Icons.chat)),
            Tab(text: 'Groups', icon: Icon(Icons.group)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'profile') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ProfileScreen()),
                );
              } else if (value == 'privacy') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const PrivacyPolicyScreen()),
                );
              } else if (value == 'about') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AboutScreen()),
                );
              } else if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                );
              } else if (value == 'blocked') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const BlockedUsersScreen()),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'profile', child: Text('My Profile')),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
              const PopupMenuItem(value: 'blocked', child: Text('Blocked Users')),
              const PopupMenuItem(value: 'privacy', child: Text('Privacy Policy')),
              const PopupMenuItem(value: 'about', child: Text('About')),
            ],
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          ChatsTabContent(),
          GroupsTabContent(),
        ],
      ),
    );
  }
}

// ---------------- Blocked Users Screen ----------------
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final dbRef = FirebaseDatabase.instance.ref();

  Future<void> _unblock(String uid) async {
    await dbRef.child('users').child(currentUid).child('blocked').child(uid).remove();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked Users')),
      body: StreamBuilder(
        stream: dbRef.child('users').child(currentUid).child('blocked').onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
            return const Center(child: Text('No blocked users'));
          }
          Map<dynamic, dynamic> blockedMap =
              snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
          List<String> uids = blockedMap.keys.map((e) => e.toString()).toList();

          return ListView.builder(
            itemCount: uids.length,
            itemBuilder: (context, index) {
              final uid = uids[index];
              return FutureBuilder(
                future: dbRef.child('users').child(uid).child('phone').get(),
                builder: (context, AsyncSnapshot<DataSnapshot> phoneSnap) {
                  String phone = phoneSnap.hasData && phoneSnap.data!.value != null
                      ? phoneSnap.data!.value.toString()
                      : 'Unknown';
                  return ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.block)),
                    title: Text(phone),
                    trailing: TextButton(
                      onPressed: () => _unblock(uid),
                      child: const Text('Unblock'),
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

// ---------------- Settings Screen ----------------
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ValueListenableBuilder<ThemeMode>(
        valueListenable: themeNotifier,
        builder: (context, currentMode, _) {
          return ListView(
            children: [
              RadioListTile<ThemeMode>(
                title: const Text('Light Mode'),
                value: ThemeMode.light,
                groupValue: currentMode,
                onChanged: (mode) => themeNotifier.value = mode!,
              ),
              RadioListTile<ThemeMode>(
                title: const Text('Dark Mode'),
                value: ThemeMode.dark,
                groupValue: currentMode,
                onChanged: (mode) => themeNotifier.value = mode!,
              ),
              RadioListTile<ThemeMode>(
                title: const Text('System Default'),
                value: ThemeMode.system,
                groupValue: currentMode,
                onChanged: (mode) => themeNotifier.value = mode!,
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------- Chats Tab ----------------
class ChatsTabContent extends StatefulWidget {
  const ChatsTabContent({super.key});

  @override
  State<ChatsTabContent> createState() => _ChatsTabContentState();
}

class _ChatsTabContentState extends State<ChatsTabContent> {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final dbRef = FirebaseDatabase.instance.ref();
  bool _loading = true;
  List<Map<String, dynamic>> _matchedUsers = [];
  Set<String> _hiddenChats = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final users = await getMatchedAppUsers(currentUid);
    final hiddenSnap = await dbRef.child('users').child(currentUid).child('hiddenChats').get();
    Set<String> hidden = {};
    if (hiddenSnap.exists && hiddenSnap.value != null) {
      Map<dynamic, dynamic> map = hiddenSnap.value as Map<dynamic, dynamic>;
      hidden = map.keys.map((e) => e.toString()).toSet();
    }
    if (mounted) {
      setState(() {
        _matchedUsers = users;
        _hiddenChats = hidden;
        _loading = false;
      });
    }
  }

  String _chatIdFor(String peerUid) {
    List<String> ids = [currentUid, peerUid];
    ids.sort();
    return '${ids[0]}_${ids[1]}';
  }

  Future<void> _deleteChat(String peerUid) async {
    final chatId = _chatIdFor(peerUid);
    await dbRef.child('users').child(currentUid).child('hiddenChats').child(chatId).set(true);
    setState(() {
      _hiddenChats.add(chatId);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final visibleUsers = _matchedUsers
        .where((u) => !_hiddenChats.contains(_chatIdFor(u['uid'])))
        .toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: visibleUsers.isEmpty
          ? ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.all(24.0),
                  child: Text(
                    'None of your phone contacts are using this app yet.\nPull down to refresh.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            )
          : ListView.builder(
              itemCount: visibleUsers.length,
              itemBuilder: (context, index) {
                final user = visibleUsers[index];
                return Dismissible(
                  key: Key(user['uid']),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (direction) async {
                    return await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Chat?'),
                            content: const Text(
                                'This will remove the chat from your list. It will reappear if a new message arrives.'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                  },
                  onDismissed: (direction) => _deleteChat(user['uid']),
                  child: ListTile(
                    leading: avatarWidget(user['photo']),
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
                      ).then((_) => _load());
                    },
                  ),
                );
              },
            ),
    );
  }
}

// ---------------- Groups Tab ----------------
class GroupsTabContent extends StatefulWidget {
  const GroupsTabContent({super.key});

  @override
  State<GroupsTabContent> createState() => _GroupsTabContentState();
}

class _GroupsTabContentState extends State<GroupsTabContent> {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final dbRef = FirebaseDatabase.instance.ref();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder(
        stream: dbRef.child('users').child(currentUid).child('groups').onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  'You are not part of any group yet.\nCreate one or join with an invite code!',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          Map<dynamic, dynamic> groupIds =
              snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
          List<String> ids = groupIds.keys.map((e) => e.toString()).toList();

          return ListView.builder(
            itemCount: ids.length,
            itemBuilder: (context, index) {
              final groupId = ids[index];
              return StreamBuilder(
                stream: dbRef.child('groups').child(groupId).onValue,
                builder: (context, AsyncSnapshot<DatabaseEvent> groupSnap) {
                  if (!groupSnap.hasData || groupSnap.data!.snapshot.value == null) {
                    return const SizedBox.shrink();
                  }
                  final group = groupSnap.data!.snapshot.value as Map<dynamic, dynamic>;
                  Map<dynamic, dynamic> members = group['members'] ?? {};
                  return ListTile(
                    leading: avatarWidget(group['photo'], fallback: Icons.group),
                    title: Text(group['name'] ?? 'Group'),
                    subtitle: Text('${members.length} members'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => GroupChatScreen(groupId: groupId),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'joinGroup',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const JoinGroupScreen()),
              );
            },
            label: const Text('Join'),
            icon: const Icon(Icons.group_add),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'createGroup',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const CreateGroupScreen()),
              );
            },
            label: const Text('Create'),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

// ---------------- Create Group Screen ----------------
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final _nameController = TextEditingController();
  bool _loading = true;
  List<Map<String, dynamic>> _contacts = [];
  Set<String> _selected = {};
  String? _photoBase64;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final users = await getMatchedAppUsers(currentUid);
    if (mounted) {
      setState(() {
        _contacts = users;
        _loading = false;
      });
    }
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 300,
      maxHeight: 300,
      imageQuality: 60,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _photoBase64 = base64Encode(bytes);
    });
  }

  Future<void> _createGroup() async {
    if (_nameController.text.trim().isEmpty || _selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a group name and select at least 1 member')),
      );
      return;
    }
    final dbRef = FirebaseDatabase.instance.ref();
    final groupRef = dbRef.child('groups').push();
    final groupId = groupRef.key!;
    final inviteCode = generateInviteCode();

    Map<String, dynamic> membersMap = {currentUid: true};
    Map<String, dynamic> adminsMap = {currentUid: true};
    Map<String, dynamic> memberPhones = {};

    final myPhone = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';
    memberPhones[currentUid] = myPhone;

    for (var c in _contacts) {
      if (_selected.contains(c['uid'])) {
        membersMap[c['uid']] = true;
        memberPhones[c['uid']] = c['phone'];
      }
    }

    await groupRef.set({
      'name': _nameController.text.trim(),
      'photo': _photoBase64 ?? '',
      'createdBy': currentUid,
      'inviteCode': inviteCode,
      'members': membersMap,
      'admins': adminsMap,
      'memberPhones': memberPhones,
    });

    await dbRef.child('inviteCodes').child(inviteCode).set(groupId);

    for (var uid in membersMap.keys) {
      await dbRef.child('users').child(uid).child('groups').child(groupId).set(true);
    }

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => GroupChatScreen(groupId: groupId)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Group')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _pickPhoto,
                        child: CircleAvatar(
                          radius: 40,
                          backgroundImage: _photoBase64 != null
                              ? MemoryImage(base64Decode(_photoBase64!))
                              : null,
                          child: _photoBase64 == null
                              ? const Icon(Icons.camera_alt, size: 30)
                              : null,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Group Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text('Select Members', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                Expanded(
                  child: _contacts.isEmpty
                      ? const Center(child: Text('No contacts using this app yet'))
                      : ListView.builder(
                          itemCount: _contacts.length,
                          itemBuilder: (context, index) {
                            final c = _contacts[index];
                            final uid = c['uid'];
                            return CheckboxListTile(
                              secondary: avatarWidget(c['photo']),
                              title: Text(c['phone'] ?? 'Unknown'),
                              value: _selected.contains(uid),
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    _selected.add(uid);
                                  } else {
                                    _selected.remove(uid);
                                  }
                                });
                              },
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: ElevatedButton(
                    onPressed: _createGroup,
                    child: const Text('Create Group'),
                  ),
                ),
              ],
            ),
    );
  }
}

// ---------------- Join Group Screen ----------------
class JoinGroupScreen extends StatefulWidget {
  const JoinGroupScreen({super.key});

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final _codeController = TextEditingController();
  bool _loading = false;

  Future<void> _join() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) return;
    setState(() => _loading = true);
    final dbRef = FirebaseDatabase.instance.ref();
    final snap = await dbRef.child('inviteCodes').child(code).get();
    if (!snap.exists || snap.value == null) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid invite code')),
        );
      }
      return;
    }
    final groupId = snap.value.toString();
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final myPhone = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';

    await dbRef.child('groups').child(groupId).child('members').child(currentUid).set(true);
    await dbRef.child('groups').child(groupId).child('memberPhones').child(currentUid).set(myPhone);
    await dbRef.child('users').child(currentUid).child('groups').child(groupId).set(true);

    setState(() => _loading = false);
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => GroupChatScreen(groupId: groupId)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Group')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Enter Invite Code',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _loading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _join,
                    child: const Text('Join Group'),
                  ),
          ],
        ),
      ),
    );
  }
}

// ---------------- Group Chat Screen ----------------
class GroupChatScreen extends StatefulWidget {
  final String groupId;
  const GroupChatScreen({super.key, required this.groupId});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final String currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final TextEditingController _msgController = TextEditingController();
  final AudioPlayer _notifPlayer = AudioPlayer();
  int _lastMessageCount = 0;
  bool _showEmojiPicker = false;

  String? _replyToText;
  String? _replyToSender;

  void _sendMessage() {
    if (_msgController.text.trim().isEmpty) return;
    final myPhone = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';
    final msgData = {
      'sender': currentUid,
      'senderPhone': myPhone,
      'type': 'text',
      'text': _msgController.text.trim(),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    if (_replyToText != null) {
      msgData['replyToText'] = _replyToText ?? '';
      msgData['replyToSender'] = _replyToSender ?? '';
    }
    _dbRef.child('groups').child(widget.groupId).child('messages').push().set(msgData);
    _msgController.clear();
    setState(() {
      _replyToText = null;
      _replyToSender = null;
    });
  }

  void _setReply(Map item) {
    setState(() {
      _replyToText = item['text'] ?? '';
      _replyToSender =
          item['sender'] == currentUid ? 'You' : (item['senderPhone'] ?? 'Unknown');
    });
  }

  void _cancelReply() {
    setState(() {
      _replyToText = null;
      _replyToSender = null;
    });
  }

  Future<void> _deleteMessage(String key, bool forEveryone) async {
    if (forEveryone) {
      await _dbRef.child('groups').child(widget.groupId).child('messages').child(key).remove();
    } else {
      await _dbRef
          .child('groups')
          .child(widget.groupId)
          .child('messages')
          .child(key)
          .child('deletedFor')
          .child(currentUid)
          .set(true);
    }
  }

  void _showMessageOptions(String key, Map item) {
    bool isMe = item['sender'] == currentUid;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                _setReply(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.pop(context);
                _deleteMessage(key, false);
              },
            ),
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for everyone'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(key, true);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _notifPlayer.dispose();
    super.dispose();
  }

  Widget _buildReplyPreviewInBubble(Map item) {
    if (item['replyToText'] == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Colors.teal, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item['replyToSender'] ?? '',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 11, color: Colors.teal)),
          Text(item['replyToText'] ?? '',
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder(
          stream: _dbRef.child('groups').child(widget.groupId).onValue,
          builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
            if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
              final group = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
              return Text(group['name'] ?? 'Group');
            }
            return const Text('Group');
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => GroupInfoScreen(groupId: widget.groupId)),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.blue.shade50,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: const Text(
              'Group calls, photo, video and file sharing are not available yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11),
            ),
          ),
          Expanded(
            child: StreamBuilder(
              stream: _dbRef.child('groups').child(widget.groupId).child('messages').onValue,
              builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
                if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                  Map<dynamic, dynamic> map =
                      snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
                  List<MapEntry<dynamic, dynamic>> entries = map.entries.toList();
                  entries.sort((a, b) => (a.value['timestamp'] ?? 0)
                      .compareTo(b.value['timestamp'] ?? 0));

                  entries = entries.where((e) {
                    final deletedFor = e.value['deletedFor'] as Map<dynamic, dynamic>?;
                    return deletedFor == null || deletedFor[currentUid] != true;
                  }).toList();

                  if (entries.length > _lastMessageCount && _lastMessageCount != 0) {
                    var lastMsg = entries.last.value;
                    if (lastMsg['sender'] != currentUid) {
                      _notifPlayer.play(AssetSource('sounds/iphone.mp3'));
                    }
                  }
                  _lastMessageCount = entries.length;

                  return ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      var key = entries[index].key.toString();
                      var item = entries[index].value;
                      bool isMe = item['sender'] == currentUid;
                      return GestureDetector(
                        onLongPress: () => _showMessageOptions(key, item),
                        child: Align(
                          alignment:
                              isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            padding: const EdgeInsets.all(10),
                            constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : Theme.of(context).colorScheme.surfaceVariant,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!isMe)
                                  Text(
                                    item['senderPhone'] ?? 'Unknown',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.teal),
                                  ),
                                _buildReplyPreviewInBubble(item),
                                Text(item['text'] ?? ''),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                }
                return const Center(child: Text('No messages yet. Say Hi 👋'));
              },
            ),
          ),
          if (_replyToText != null)
            Container(
              width: double.infinity,
              color: Colors.teal.withOpacity(0.1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.reply, size: 18, color: Colors.teal),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Replying to $_replyToSender',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.teal)),
                        Text(_replyToText ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: _cancelReply),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                      _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions_outlined),
                  onPressed: () {
                    setState(() => _showEmojiPicker = !_showEmojiPicker);
                    if (_showEmojiPicker) FocusScope.of(context).unfocus();
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    onTap: () {
                      if (_showEmojiPicker) setState(() => _showEmojiPicker = false);
                    },
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _sendMessage),
              ],
            ),
          ),
          if (_showEmojiPicker)
            SizedBox(
              height: 250,
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  _msgController.text += emoji.emoji;
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- Group Info Screen ----------------
class GroupInfoScreen extends StatefulWidget {
  final String groupId;
  const GroupInfoScreen({super.key, required this.groupId});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  final String currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  Future<void> _editName(String currentName) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Group Name'),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await _dbRef.child('groups').child(widget.groupId).child('name').set(newName);
    }
  }

  Future<void> _editPhoto() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 300,
      maxHeight: 300,
      imageQuality: 60,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _dbRef.child('groups').child(widget.groupId).child('photo').set(base64Encode(bytes));
  }

  Future<void> _toggleAdmin(String uid, bool isCurrentlyAdmin) async {
    if (isCurrentlyAdmin) {
      await _dbRef.child('groups').child(widget.groupId).child('admins').child(uid).remove();
    } else {
      await _dbRef.child('groups').child(widget.groupId).child('admins').child(uid).set(true);
    }
  }

  Future<void> _removeMember(String uid) async {
    await _dbRef.child('groups').child(widget.groupId).child('members').child(uid).remove();
    await _dbRef.child('groups').child(widget.groupId).child('admins').child(uid).remove();
    await _dbRef.child('groups').child(widget.groupId).child('memberPhones').child(uid).remove();
    await _dbRef.child('users').child(uid).child('groups').child(widget.groupId).remove();
  }

  Future<void> _leaveGroup() async {
    await _removeMember(currentUid);
    if (mounted) {
      Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  Future<void> _addMembers(List<String> currentMemberUids) async {
    final contacts = await getMatchedAppUsers(currentUid);
    final available =
        contacts.where((c) => !currentMemberUids.contains(c['uid'])).toList();
    if (available.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All your contacts are already in this group')),
        );
      }
      return;
    }
    Set<String> selected = {};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Text('Add Members', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  ...available.map((c) => CheckboxListTile(
                        title: Text(c['phone'] ?? 'Unknown'),
                        value: selected.contains(c['uid']),
                        onChanged: (val) {
                          setModalState(() {
                            if (val == true) {
                              selected.add(c['uid']);
                            } else {
                              selected.remove(c['uid']);
                            }
                          });
                        },
                      )),
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: ElevatedButton(
                      onPressed: () async {
                        for (var uid in selected) {
                          final match = available.firstWhere((c) => c['uid'] == uid);
                          await _dbRef
                              .child('groups')
                              .child(widget.groupId)
                              .child('members')
                              .child(uid)
                              .set(true);
                          await _dbRef
                              .child('groups')
                              .child(widget.groupId)
                              .child('memberPhones')
                              .child(uid)
                              .set(match['phone']);
                          await _dbRef
                              .child('users')
                              .child(uid)
                              .child('groups')
                              .child(widget.groupId)
                              .set(true);
                        }
                        if (mounted) Navigator.pop(context);
                      },
                      child: const Text('Add Selected'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Group Info')),
      body: StreamBuilder(
        stream: _dbRef.child('groups').child(widget.groupId).onValue,
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final group = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
          Map<dynamic, dynamic> members = group['members'] ?? {};
          Map<dynamic, dynamic> admins = group['admins'] ?? {};
          Map<dynamic, dynamic> memberPhones = group['memberPhones'] ?? {};
          List<String> memberUids = members.keys.map((e) => e.toString()).toList();
          bool amAdmin = admins.containsKey(currentUid);
          String? photo = group['photo'];

          return ListView(
            children: [
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: amAdmin ? _editPhoto : null,
                  child: CircleAvatar(
                    radius: 45,
                    backgroundImage: (photo != null && photo.isNotEmpty)
                        ? MemoryImage(base64Decode(photo))
                        : null,
                    child: (photo == null || photo.isEmpty)
                        ? const Icon(Icons.group, size: 40)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      group['name'] ?? 'Group',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (amAdmin)
                      IconButton(
                        icon: const Icon(Icons.edit, size: 18),
                        onPressed: () => _editName(group['name'] ?? ''),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text('Invite Code: ${group['inviteCode'] ?? ''}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.teal)),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: group['inviteCode'] ?? ''));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite code copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy Code'),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${memberUids.length} Members',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (amAdmin)
                      TextButton.icon(
                        onPressed: () => _addMembers(memberUids),
                        icon: const Icon(Icons.person_add, size: 18),
                        label: const Text('Add'),
                      ),
                  ],
                ),
              ),
              ...memberUids.map((uid) {
                bool isAdmin = admins.containsKey(uid);
                String phone = memberPhones[uid] ?? 'Unknown';
                bool isMe = uid == currentUid;
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(isMe ? '$phone (You)' : phone),
                  subtitle: isAdmin
                      ? const Text('Admin', style: TextStyle(color: Colors.teal))
                      : null,
                  trailing: (amAdmin && !isMe)
                      ? PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'toggleAdmin') {
                              _toggleAdmin(uid, isAdmin);
                            } else if (value == 'remove') {
                              _removeMember(uid);
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'toggleAdmin',
                              child: Text(isAdmin ? 'Remove Admin' : 'Make Admin'),
                            ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove from Group'),
                            ),
                          ],
                        )
                      : null,
                );
              }),
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _leaveGroup,
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text('Leave Group'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------- Profile Screen ----------------
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final dbRef = FirebaseDatabase.instance.ref();
  String? _photoBase64;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snap = await dbRef.child('users').child(currentUid).child('photo').get();
    if (snap.exists && snap.value != null) {
      _photoBase64 = snap.value.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 300,
      maxHeight: 300,
      imageQuality: 60,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final b64 = base64Encode(bytes);
    await dbRef.child('users').child(currentUid).child('photo').set(b64);
    setState(() => _photoBase64 = b64);
  }

  @override
  Widget build(BuildContext context) {
    final phone = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _pickPhoto,
                    child: CircleAvatar(
                      radius: 55,
                      backgroundImage: (_photoBase64 != null && _photoBase64!.isNotEmpty)
                          ? MemoryImage(base64Decode(_photoBase64!))
                          : null,
                      child: (_photoBase64 == null || _photoBase64!.isEmpty)
                          ? const Icon(Icons.camera_alt, size: 36)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Tap photo to change',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 24),
                  Text(phone, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
    );
  }
}

// ---------------- Privacy Policy Screen ----------------
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: const Padding(
        padding: EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Privacy Policy',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 12),
              Text(
                'This app respects your privacy. Here is how your data is handled:',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 12),
              Text('• Messages: Text messages are stored securely to enable delivery between you and your contacts or groups.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('• Calls & Files: Audio calls, video calls, photos, videos, and files (in 1-on-1 chats) are sent directly (peer-to-peer) between devices and are not stored on any server.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('• Contacts: We access your phone contacts only to check which of your contacts also use this app. Your contacts are not uploaded or shared with anyone.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('• Phone Number: Your phone number is used only for account verification and to let your contacts find you on this app.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('• Blocking: If you block a contact, they will no longer be able to send you messages or call you.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('• Profile & Group Photos: Stored securely to display within the app to your contacts and group members.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 8),
              Text('• Microphone & Camera: Used only during calls, voice messages, and when you choose to send photos/videos.',
                  style: TextStyle(fontSize: 14)),
              SizedBox(height: 12),
              Text(
                'We do not sell or share your personal data with third parties.',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 20),
              Text(
                'Developed by Riaz Ahmed',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- About Screen ----------------
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: const Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'P2P Media Chat',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('Version 1.0.0', style: TextStyle(fontSize: 14)),
            SizedBox(height: 16),
            Text(
              'Developed by Riaz Ahmed',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'A private, peer-to-peer messaging and calling app built for secure, direct communication.',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
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

// ---------------- Inline Video Player Page ----------------
class VideoPlayerPage extends StatefulWidget {
  final String filePath;
  const VideoPlayerPage({super.key, required this.filePath});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          _controller.play();
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: _initialized
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: _initialized
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _controller.value.isPlaying ? _controller.pause() : _controller.play();
                });
              },
              child:
                  Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}

// ---------------- Private Chat Screen (1-on-1) ----------------
class ChatScreen extends StatefulWidget {
  final String peerUid;
  final String peerName;
  const ChatScreen({super.key, required this.peerUid, required this.peerName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final String currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  final TextEditingController _msgController = TextEditingController();
  final AudioPlayer _notifPlayer = AudioPlayer();
  late String chatId;
  int _lastMessageCount = 0;
  bool _screenIsActive = true;
  bool _showEmojiPicker = false;
  bool _peerTyping = false;
  bool _iBlockedPeer = false;
  bool _checkedBlockStatus = false;

  String? _replyToId;
  String? _replyToText;
  String? _replyToSender;

  RTCPeerConnection? _fileConn;
  RTCDataChannel? _fileChannel;
  bool _fileChannelReady = false;
  final Map<String, List<Uint8List?>> _recvChunks = {};
  final Map<String, Map<String, dynamic>> _recvMeta = {};
  final Map<String, String> _localFilePaths = {};

  final Record _audioRecorder = Record();
  bool _isRecording = false;
  String? _recordingPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    List<String> ids = [currentUid, widget.peerUid];
    ids.sort();
    chatId = '${ids[0]}_${ids[1]}';
    _listenForNewMessages();
    _setupFileChannel();
    _listenForTyping();
    _msgController.addListener(_onTextChanged);
    _checkBlockStatus();
    _dbRef.child('users').child(currentUid).child('hiddenChats').child(chatId).remove();
  }

  Future<void> _checkBlockStatus() async {
    final blocked = await isUserBlocked(currentUid, widget.peerUid);
    if (mounted) {
      setState(() {
        _iBlockedPeer = blocked;
        _checkedBlockStatus = true;
      });
    }
  }

  Future<void> _toggleBlock() async {
    if (_iBlockedPeer) {
      await _dbRef.child('users').child(currentUid).child('blocked').child(widget.peerUid).remove();
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Block this contact?'),
          content: const Text('They will no longer be able to message or call you.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Block')),
          ],
        ),
      );
      if (confirm != true) return;
      await _dbRef.child('users').child(currentUid).child('blocked').child(widget.peerUid).set(true);
    }
    setState(() => _iBlockedPeer = !_iBlockedPeer);
  }

  void _onTextChanged() {
    _dbRef
        .child('chats')
        .child(chatId)
        .child('typing')
        .child(currentUid)
        .set(_msgController.text.trim().isNotEmpty);
  }

  void _listenForTyping() {
    _dbRef
        .child('chats')
        .child(chatId)
        .child('typing')
        .child(widget.peerUid)
        .onValue
        .listen((event) {
      final isTyping = event.snapshot.value == true;
      if (mounted) setState(() => _peerTyping = isTyping);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _screenIsActive = state == AppLifecycleState.resumed;
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
          _dbRef.child('users').child(currentUid).child('hiddenChats').child(chatId).remove();
        }
      }
      _lastMessageCount = count;

      _updateIncomingMessageStatuses(map);
    });
  }

  void _updateIncomingMessageStatuses(Map<dynamic, dynamic> map) {
    map.forEach((key, value) {
      final msg = value as Map<dynamic, dynamic>;
      if (msg['sender'] != currentUid) {
        final currentStatus = msg['status'] ?? 'sent';
        final newStatus = _screenIsActive ? 'seen' : 'delivered';
        if (currentStatus != 'seen' &&
            (newStatus == 'seen' || currentStatus == 'sent')) {
          _dbRef
              .child('chats')
              .child(chatId)
              .child('messages')
              .child(key)
              .child('status')
              .set(newStatus);
        }
      }
    });
  }

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
    if (_iBlockedPeer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unblock this contact to send messages')),
      );
      return;
    }
    if (_msgController.text.trim().isNotEmpty) {
      final msgData = {
        'sender': currentUid,
        'type': 'text',
        'text': _msgController.text.trim(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'sent',
      };
      if (_replyToId != null) {
        msgData['replyToText'] = _replyToText ?? '';
        msgData['replyToSender'] = _replyToSender ?? '';
      }
      _dbRef.child('chats').child(chatId).child('messages').push().set(msgData);
      _msgController.clear();
      _dbRef.child('chats').child(chatId).child('typing').child(currentUid).set(false);
      setState(() {
        _replyToId = null;
        _replyToText = null;
        _replyToSender = null;
      });
    }
  }

  void _setReply(Map item) {
    setState(() {
      _replyToId = item['timestamp']?.toString();
      _replyToText = item['type'] == 'text'
          ? (item['text'] ?? '')
          : '[${item['type'] ?? 'file'}]';
      _replyToSender = item['sender'] == currentUid ? 'You' : widget.peerName;
    });
  }

  void _cancelReply() {
    setState(() {
      _replyToId = null;
      _replyToText = null;
      _replyToSender = null;
    });
  }

  Future<void> _deleteMessage(String key, bool forEveryone) async {
    if (forEveryone) {
      await _dbRef.child('chats').child(chatId).child('messages').child(key).remove();
    } else {
      await _dbRef
          .child('chats')
          .child(chatId)
          .child('messages')
          .child(key)
          .child('deletedFor')
          .child(currentUid)
          .set(true);
    }
  }

  void _showMessageOptions(String key, Map item) {
    bool isMe = item['sender'] == currentUid;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                _setReply(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.pop(context);
                _deleteMessage(key, false);
              },
            ),
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for everyone'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(key, true);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _startCall(bool isVideo) async {
    if (_iBlockedPeer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unblock this contact to call them')),
      );
      return;
    }
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

  Future<void> _saveToGallery(String type, String localPath, String fileName) async {
    try {
      var result = await ImageGallerySaver.saveFile(localPath, name: fileName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result != null ? 'Saved to Gallery' : 'Failed to save')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  Widget _buildMessageContent(Map item) {
    String type = item['type'] ?? 'text';
    if (type == 'text') {
      return Text(item['text'] ?? '');
    }

    String? localPath = _localFilePaths[item['fileId']];
    String fileName = item['fileName'] ?? 'File';

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
      if (localPath == null) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image, size: 20),
            const SizedBox(width: 4),
            Flexible(
              child: Text('$fileName (receiving...)', overflow: TextOverflow.ellipsis),
            ),
          ],
        );
      }
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(localPath), width: 180, fit: BoxFit.cover),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: GestureDetector(
              onTap: () => _saveToGallery('image', localPath, fileName),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.download, color: Colors.white, size: 16),
              ),
            ),
          ),
        ],
      );
    }

    if (type == 'video') {
      if (localPath == null) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam, size: 20),
            const SizedBox(width: 4),
            Flexible(
              child: Text('$fileName (receiving...)', overflow: TextOverflow.ellipsis),
            ),
          ],
        );
      }
      return GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => VideoPlayerPage(filePath: localPath)),
          );
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 180,
              height: 120,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 48),
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: GestureDetector(
                onTap: () => _saveToGallery('video', localPath, fileName),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.download, color: Colors.white, size: 16),
                ),
              ),
            ),
          ],
        ),
      );
    }

    IconData icon = Icons.insert_drive_file;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(localPath != null ? icon : Icons.hourglass_bottom, size: 20),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            localPath != null ? fileName : '$fileName (receiving...)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildReplyPreviewInBubble(Map item) {
    if (item['replyToText'] == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Colors.teal, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item['replyToSender'] ?? '',
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 11, color: Colors.teal),
          ),
          Text(
            item['replyToText'] ?? '',
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _msgController.removeListener(_onTextChanged);
    _dbRef.child('chats').child(chatId).child('typing').child(currentUid).set(false);
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.peerName),
            if (_peerTyping)
              const Text('typing...',
                  style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () => _startCall(false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () => _startCall(true),
          ),
          if (_checkedBlockStatus)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'block') _toggleBlock();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'block',
                  child: Text(_iBlockedPeer ? 'Unblock' : 'Block'),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (_iBlockedPeer)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: const Text(
                'You have blocked this contact',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
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
                  List<MapEntry<dynamic, dynamic>> entries = map.entries.toList();
                  entries.sort((a, b) => (a.value['timestamp'] ?? 0)
                      .compareTo(b.value['timestamp'] ?? 0));

                  entries = entries.where((e) {
                    final deletedFor = e.value['deletedFor'] as Map<dynamic, dynamic>?;
                    return deletedFor == null || deletedFor[currentUid] != true;
                  }).toList();

                  return ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      var key = entries[index].key.toString();
                      var item = entries[index].value;
                      bool isMe = item['sender'] == currentUid;
                      return GestureDetector(
                        onLongPress: () => _showMessageOptions(key, item),
                        child: Align(
                          alignment:
                              isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            padding: const EdgeInsets.all(10),
                            constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : Theme.of(context).colorScheme.surfaceVariant,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildReplyPreviewInBubble(item),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(child: _buildMessageContent(item)),
                                    if (isMe) ...[
                                      const SizedBox(width: 4),
                                      _buildTickIcon(item['status'] ?? 'sent'),
                                    ],
                                  ],
                                ),
                              ],
                            ),
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
          if (_replyToId != null)
            Container(
              width: double.infinity,
              color: Colors.teal.withOpacity(0.1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.reply, size: 18, color: Colors.teal),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Replying to $_replyToSender',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.teal),
                        ),
                        Text(
                          _replyToText ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _cancelReply,
                  ),
                ],
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
                IconButton(
                  icon: Icon(
                    _showEmojiPicker
                        ? Icons.keyboard
                        : Icons.emoji_emotions_outlined,
                  ),
                  onPressed: () {
                    setState(() => _showEmojiPicker = !_showEmojiPicker);
                    if (_showEmojiPicker) FocusScope.of(context).unfocus();
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    onTap: () {
                      if (_showEmojiPicker) {
                        setState(() => _showEmojiPicker = false);
                      }
                    },
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
          if (_showEmojiPicker)
            SizedBox(
              height: 250,
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  _msgController.text += emoji.emoji;
                },
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
    required this.isVideo
