// lib/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../providers/cart_model.dart';
import 'item_list_screen.dart';
import '../constants/config.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _baseCtrl = TextEditingController();

  bool _remember = true;
  bool _loading = false;
  String? _error;

  static const String _prefsKeyLastBase = 'last_base_url';

  @override
  void initState() {
    super.initState();
    // load saved base url (async)
    _loadSavedBaseUrl();
  }

  Future<void> _loadSavedBaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKeyLastBase);
      if (saved != null && saved.isNotEmpty) {
        _baseCtrl.text = saved;
        AppConfig.baseUrl = saved;
      } else {
        // fallback to default AppConfig
        _baseCtrl.text = AppConfig.baseUrl;
      }
    } catch (e) {
      // ignore prefs errors and keep default
      _baseCtrl.text = AppConfig.baseUrl;
    }
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    _baseCtrl.dispose();
    super.dispose();
  }

  bool _isValidUrl(String s) {
    if (s.trim().isEmpty) return false;
    final uri = Uri.tryParse(s.trim());
    // Accept http/https, or host:port (we normalize later by adding http:// if missing)
    return uri != null && (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https') || (!uri.hasScheme && s.trim().contains(':')));
  }

  Future<void> _saveLastBaseUrl(String baseUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyLastBase, baseUrl);
    } catch (e) {
      // ignore write errors
    }
  }

  @override
  Widget build(BuildContext context) {
    // Note: we intentionally do NOT read a global ApiProvider from the tree here,
    // because we will create a provider instance for the entered base URL on login.
    return Scaffold(
      appBar: AppBar(title: const Text('ERPNext POS Login')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _baseCtrl,
              decoration: const InputDecoration(
                labelText: 'Base URL (e.g. http://192.168.2.114:8000)',
                hintText: 'http://your-erp-host:8000',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: 'Username')),
            const SizedBox(height: 8),
            TextField(controller: _pwdCtrl, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
            Row(
              children: [
                Checkbox(value: _remember, onChanged: (v) => setState(() => _remember = v ?? true)),
                const Text('Remember session (persist cookies)'),
              ],
            ),
            if (_error != null) Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : () async {
                  setState(() { _loading = true; _error = null; });

                  final enteredBase = _baseCtrl.text.trim();
                  if (enteredBase.isEmpty) {
                    setState(() { _error = 'Please enter Base URL'; _loading = false; });
                    return;
                  }

                  // Normalize: prepend http if scheme missing
                  String normalizedBase = enteredBase;
                  if (!enteredBase.startsWith('http://') && !enteredBase.startsWith('https://')) {
                    normalizedBase = 'http://$enteredBase';
                  }

                  if (!_isValidUrl(normalizedBase)) {
                    setState(() { _error = 'Invalid Base URL'; _loading = false; });
                    return;
                  }

                  try {
                    // Update AppConfig so other parts can read it if needed
                    AppConfig.baseUrl = normalizedBase;

                    // Create a fresh ApiProvider bound to this base URL (handles cookies, dio)
                    final prov = await ApiProvider.create(base: normalizedBase);

                    // Attempt login using that provider
                    final resp = await prov.client.login(_userCtrl.text.trim(), _pwdCtrl.text);

                    if (resp.response.statusCode == 200) {
                      // Save last base URL for next time (persist)
                      await _saveLastBaseUrl(normalizedBase);

                      // Login successful. Navigate to ItemListScreen but provide the provider
                      // to downstream widgets so they use the same Dio + cookie jar.
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => Provider<ApiProvider>.value(
                            value: prov,
                            child: const ItemListScreen(),
                          ),
                        ),
                      );
                    } else {
                      // Login failed - show server message if available
                      final statusMsg = resp.response.statusMessage ?? resp.response.data?.toString() ?? 'Login failed';
                      setState(() => _error = 'Login failed: $statusMsg');
                    }
                  } catch (e, st) {
                    // Provide a helpful error
                    setState(() => _error = 'Login error: ${e.toString()}');
                  } finally {
                    if (mounted) setState(() => _loading = false);
                  }
                },
                child: _loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Login'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
