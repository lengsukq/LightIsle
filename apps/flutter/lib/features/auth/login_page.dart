import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../../core/user_facing_error.dart';
import 'nas_discovery_picker.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onSignedIn,
    this.expired = false,
    this.notice,
  });
  final String? notice;
  final FutureOr<void> Function(LightIsleApi, Map<String, dynamic>) onSignedIn;
  final bool expired;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _fingerprint = TextEditingController();
  bool _busy = false, _hide = true;
  bool _securityExpanded = false;
  SharedPreferences? _preferences;
  String? _pinOrigin;
  String? _error;
  LightIsleApi? _connecting;
  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (mounted) {
        _preferences = preferences;
        if (_server.text.isEmpty) {
          _server.text = preferences.getString('lightisle.server') ?? '';
        }
        if (_fingerprint.text.isEmpty) _addressChanged(_server.text);
      }
    } catch (_) {
      /* Remembering an address is optional. */
    }
  }

  String? _httpsOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? uri.origin
        : null;
  }

  void _addressChanged(String value) {
    final origin = _httpsOrigin(value);
    if (origin == _pinOrigin) return;
    _pinOrigin = origin;
    _fingerprint.text = origin == null
        ? ''
        : _preferences?.getString('lightisle.certificatePin.$origin') ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    LightIsleApi? api;
    try {
      api = LightIsleApi(
        _server.text.trim(),
        // Accept both advertised schemes without an extra UI toggle, but the
        // transport still refuses cleartext connections to public IPs.
        allowInsecureHttp: true,
        certificateFingerprint: _fingerprint.text.trim().isEmpty
            ? null
            : _fingerprint.text.trim(),
      );
      _connecting = api;
      final status = await api.get('/api/v2/auth/status');
      if (status['configured'] != true) {
        throw StateError('服务尚未初始化，请先在 Mac 原生管理端创建首任管理员。');
      }
      final identity = await api.send(
        'POST',
        '/api/v2/auth/login',
        body: {'username': _username.text.trim(), 'password': _password.text},
      );
      if (!mounted) {
        api.close();
        return;
      }
      if (!api.authenticated) throw StateError('服务未返回可用会话，请检查连接地址。');
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('lightisle.server', _server.text.trim());
        final origin = _httpsOrigin(_server.text);
        if (origin != null) {
          final key = 'lightisle.certificatePin.$origin';
          if (_fingerprint.text.trim().isEmpty) {
            await preferences.remove(key);
          } else {
            await preferences.setString(key, _fingerprint.text.trim());
          }
        }
      } catch (_) {
        /* The session is saved separately in OS-protected storage. */
      }
      if (!mounted) {
        api.close();
        return;
      }
      _password.clear();
      _connecting = null;
      await widget.onSignedIn(api, identity);
    } catch (error) {
      api?.close();
      if (mounted) {
        setState(() {
          _error = userFacingError(error);
        });
      }
    } finally {
      _connecting = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _connecting?.close();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _fingerprint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: AutofillGroup(
              child: IsleSurface(
                radius: 30,
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 400 ? 22 : 36,
                ),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Theme.of(context).colorScheme.primary
                                    .withValues(alpha: 0.25),
                                blurRadius: 28,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const IsleBrandMark(size: 76),
                        ),
                      ),
                      const ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text('第一次连接？查看 3 步设置'),
                        children: [
                          ListTile(
                            leading: Icon(Icons.laptop_mac_rounded),
                            title: Text('1. 在 Mac 上启动 LightIsle'),
                            subtitle: Text('首次使用请先完成管理员账号初始化，并保持 NAS 服务运行。'),
                          ),
                          ListTile(
                            leading: Icon(Icons.wifi_rounded),
                            title: Text('2. 确认连接方式'),
                            subtitle: Text(
                              '手机与 Mac 处于同一家庭网络时，点击“查找附近的 LightIsle”；也可以填入 Mac 显示的连接地址。',
                            ),
                          ),
                          ListTile(
                            leading: Icon(Icons.verified_user_outlined),
                            title: Text('3. 登录并核对安全信息'),
                            subtitle: Text(
                              '使用 Mac 上创建的用户名和密码。若启用自签名 HTTPS，需核对 Mac 显示的 SHA-256 证书指纹。',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '轻屿 LightIsle',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '连接你的个人 NAS，随时查看文件、照片与影视。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (widget.expired) const Notice('登录已过期或失效，请重新登录。'),
                      if (widget.notice != null)
                        Notice(widget.notice!, error: true),
                      TextFormField(
                        controller: _server,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: _addressChanged,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'http://192.168.1.100:16666',
                          prefixIcon: Icon(Icons.dns_outlined, size: 20),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? '请输入 Mac 管理端显示的连接地址'
                            : null,
                      ),
                      NasDiscoveryPicker(
                        enabled: !_busy,
                        onSelected: (server) async {
                          if (_busy) return;
                          _server.text = server.address;
                          _addressChanged(server.address);
                          setState(() {
                            _securityExpanded = true;
                            _error = null;
                          });
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '家庭局域网默认使用 HTTP；需要加密时可在 Mac 设置中开启 HTTPS。HTTP 请勿暴露到公网。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _username,
                        enabled: !_busy,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          prefixIcon: Icon(
                            Icons.person_outline_rounded,
                            size: 20,
                          ),
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请输入用户名' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _hide,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: '密码',
                          prefixIcon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            tooltip: _hide ? '显示密码' : '隐藏密码',
                            onPressed: () => setState(() => _hide = !_hide),
                            icon: Icon(
                              _hide
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (v) =>
                            v == null || v.isEmpty ? '请输入密码' : null,
                        onFieldSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _securityExpanded = !_securityExpanded,
                                ),
                          icon: Icon(
                            _securityExpanded
                                ? Icons.expand_less
                                : Icons.shield_outlined,
                          ),
                          label: Text(
                            _fingerprint.text.isEmpty
                                ? '连接安全设置'
                                : '连接安全设置 · 已记住证书指纹',
                          ),
                        ),
                      ),
                      if (_securityExpanded) ...[
                        TextFormField(
                          key: const Key('certificateFingerprint'),
                          controller: _fingerprint,
                          enabled: !_busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          minLines: 2,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '连接验证信息（加密连接时使用）',
                            helperText: '第一次连接 Mac 时，从 Mac「连接其他设备」中复制验证信息并仔细核对。使用已受信任的证书时可留空。',
                            helperMaxLines: 5,
                            prefixIcon: Icon(
                              Icons.verified_user_outlined,
                              size: 20,
                            ),
                          ),
                          validator: (value) {
                            final pin = (value ?? '').replaceAll(
                              RegExp(r'[:\s]'),
                              '',
                            );
                            if (pin.isEmpty) return null;
                            if (_httpsOrigin(_server.text) == null) {
                              return '证书指纹仅用于 HTTPS 地址';
                            }
                            return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(pin)
                                ? null
                                : '请输入完整的 64 位 SHA-256 指纹';
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (_error != null) Notice(_error!, error: true),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _busy ? null : _login,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.login_rounded, size: 20),
                        label: Text(_busy ? '正在连接…' : '连接并登录'),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        '请保持 Mac 原生管理端运行。局域网连接默认自动开启，首次管理员初始化、存储授权和备份恢复仍在 Mac 管理端完成。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
