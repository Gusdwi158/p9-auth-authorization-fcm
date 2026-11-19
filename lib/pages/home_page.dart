import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import '../services/kos_service.dart';
import '../services/profile_service.dart';
import '../widgets/role_guard.dart';
import 'login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Future<UserProfile?> _profileFuture;
  final KosService _kosService = KosService();
  List<KosRow> _kosList = [];
  bool _loadingKos = true;

  @override
  void initState() {
    super.initState();
    _profileFuture = ProfileService().getMyProfile();
    _loadKos();
  }

  Future<void> _loadKos() async {
    setState(() => _loadingKos = true);
    try {
      final data = await _kosService.fetchAll();
      if (!mounted) return;
      setState(() {
        _kosList = data;
        _loadingKos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingKos = false);
      _showSnack('Gagal memuat data kos: $e');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _logout() async {
    await AuthService.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  Future<void> _showKosFormDialog({KosRow? existing}) async {
    final nameC = TextEditingController(text: existing?['name'] ?? '');
    final addressC = TextEditingController(text: existing?['address'] ?? '');
    final priceC = TextEditingController(
      text: existing?['price']?.toString() ?? '',
    );
    final isEdit = existing != null;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'Edit Kos' : 'Tambah Kos Baru'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(labelText: 'Nama Kos'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: addressC,
              decoration: const InputDecoration(labelText: 'Alamat'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: priceC,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Harga / Bulan (Rp)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameC.text.trim();
              final address = addressC.text.trim();
              final price = int.tryParse(priceC.text.trim()) ?? 0;
              if (name.isEmpty) return;

              if (isEdit) {
                final ok = await _kosService.update(existing['id'], {
                  'name': name,
                  'address': address,
                  'price': price,
                });
                if (!ctx.mounted) return;
                Navigator.pop(ctx, ok);
              } else {
                await _kosService.add(
                  name: name,
                  address: address,
                  price: price,
                );
                if (!ctx.mounted) return;
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );

    if (saved == true) {
      _showSnack(
        isEdit
            ? '[ALLOWED] Data kos berhasil diperbarui'
            : '[ALLOWED] Kos baru berhasil ditambahkan',
      );
      _loadKos();
    } else if (saved == false && isEdit) {
      _showSnack('[DENIED] Ditolak oleh kebijakan RLS!');
    }
  }

  /// Praktik 6 — Security Testing: Uji operasi User B terhadap data User A
  Future<void> _runSecurityTest() async {
    final myId = Supabase.instance.client.auth.currentUser!.id;
    final otherKos = _kosList.firstWhere(
      (k) => k['owner_id'] != myId,
      orElse: () => <String, dynamic>{},
    );

    if (otherKos.isEmpty) {
      _showSnack(
        'Belum ada data kos milik user lain. Buat kos pakai akun Owner A terlebih dahulu.',
      );
      return;
    }

    final targetId = otherKos['id'] as String;
    final targetOwnerId = otherKos['owner_id'] as String;
    final logs = <String>[];

    // 1. User B mencoba UPDATE kos milik User A -> harus DENIED (false)
    final updated = await _kosService.update(targetId, {
      'name': 'DIUBAH USER B',
    });
    logs.add(
      updated
          ? '[FAIL] UPDATE berhasil (RLS bocor!)'
          : '[PASS] UPDATE data user lain ditolak RLS (0 rows)',
    );

    // 2. User B mencoba DELETE kos milik User A -> harus DENIED (false)
    final deleted = await _kosService.delete(targetId);
    logs.add(
      deleted
          ? '[FAIL] DELETE berhasil (RLS bocor!)'
          : '[PASS] DELETE data user lain ditolak RLS (0 rows)',
    );

    // 3. User B mencoba INSERT atas nama User A -> harus ERROR 42501
    try {
      await Supabase.instance.client.from('kos').insert({
        'owner_id': targetOwnerId,
        'name': 'Kos Palsu',
      });
      logs.add('[FAIL] INSERT atas nama user lain berhasil');
    } on PostgrestException catch (e) {
      logs.add('[PASS] INSERT ditolak RLS (${e.code}: ${e.message})');
    }

    for (final line in logs) {
      debugPrint(line);
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hasil Security Test (RLS)'),
        content: Text(logs.join('\n\n')),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = Supabase.instance.client.auth.currentUser?.id;

    return FutureBuilder<UserProfile?>(
      future: _profileFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final p = snap.data;
        if (snap.hasError || p == null) {
          return const Scaffold(
            body: Center(child: Text('Gagal memuat profil')),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text('KosFinder (${p.role})'),
            actions: [
              IconButton(
                tooltip: 'Uji Keamanan RLS',
                icon: const Icon(Icons.security),
                onPressed: _runSecurityTest,
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _loadKos,
              ),
              IconButton(
                tooltip: 'Logout',
                icon: const Icon(Icons.logout),
                onPressed: _logout,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(p.name.isEmpty ? p.email : p.name),
                subtitle: Text('${p.email} • ${p.role}'),
              ),
              const Divider(),
              if (p.isOwner || p.isAdmin)
                const ListTile(
                  leading: Icon(Icons.home_work),
                  title: Text('Mode Pemilik Kos (My Kos & Manajemen)'),
                ),
              if (p.isAdmin)
                const ListTile(
                  leading: Icon(Icons.admin_panel_settings),
                  title: Text('Kelola Data (Admin)'),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'Daftar Kos',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              if (_loadingKos)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_kosList.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('Belum ada data kos.')),
                )
              else
                ..._kosList.map((kos) {
                  final isMine = kos['owner_id'] == myId;
                  return ListTile(
                    leading: Icon(
                      Icons.apartment,
                      color: isMine ? Colors.indigo : Colors.grey,
                    ),
                    title: Text(kos['name'] ?? '-'),
                    subtitle: Text(
                      '${kos['address'] ?? '-'} • Rp ${kos['price'] ?? 0}/bln'
                      '${isMine ? ' (Milik Anda)' : ''}',
                    ),
                    trailing: isMine
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () =>
                                    _showKosFormDialog(existing: kos),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                onPressed: () async {
                                  final ok = await _kosService.delete(
                                    kos['id'],
                                  );
                                  if (!mounted) return;
                                  _showSnack(
                                    ok
                                        ? '[ALLOWED] Kos milik sendiri dihapus'
                                        : '[DENIED] Ditolak oleh RLS',
                                  );
                                  _loadKos();
                                },
                              ),
                            ],
                          )
                        : null,
                  );
                }),
            ],
          ),
          floatingActionButton: RoleGuard(
            role: p.role,
            allowed: const ['owner', 'admin'],
            child: FloatingActionButton.extended(
              onPressed: () => _showKosFormDialog(),
              icon: const Icon(Icons.add_home),
              label: const Text('Tambah Kos'),
            ),
          ),
        );
      },
    );
  }
}
