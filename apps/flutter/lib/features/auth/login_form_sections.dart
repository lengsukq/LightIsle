import 'package:flutter/material.dart';

import '../../core/insecure_http_allowlist.dart';
import '../../core/login_history_store.dart';
import '../../core/nas_discovery.dart';
import '../../core/widgets.dart';
import 'login_flow_background.dart';
import 'login_history_section.dart';
import 'nas_discovery_picker.dart';

/// Server address field, normalized URL preview, LAN discovery picker, and
/// live server latency probe bar.
class LoginServerAddressSection extends StatelessWidget {
  const LoginServerAddressSection({
    super.key,
    required this.controller,
    required this.normalizedServer,
    required this.busy,
    required this.latency,
    required this.onChanged,
    required this.onDiscoveredSelected,
    required this.onProbe,
  });

  final TextEditingController controller;
  final String normalizedServer;
  final bool busy;
  final ServerLatencyResult? latency;
  final ValueChanged<String> onChanged;
  final ValueChanged<NasDiscoveryServer> onDiscoveredSelected;
  final VoidCallback onProbe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final trimmed = controller.text.trim();
    final showNormalizedHint =
        trimmed.isNotEmpty &&
        !trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: controller,
          enabled: !busy,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          onChanged: onChanged,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '服务器地址',
            hintText: '192.168.1.100:16666',
            prefixIcon: Icon(Icons.dns_outlined, size: 19),
          ),
          validator: (v) =>
              v == null || v.trim().isEmpty ? '请输入 Mac 管理端显示的连接地址' : null,
        ),
        if (showNormalizedHint)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              '将连接：$normalizedServer',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              NasDiscoveryPicker(
                enabled: !busy,
                onSelected: onDiscoveredSelected,
              ),
              CurrentServerLatencyBar(
                serverUrl: normalizedServer,
                result: latency,
                enabled: !busy,
                onProbe: onProbe,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Username and password inputs arranged side-by-side on medium viewports or
/// stacked on compact / split-wide viewports.
class LoginCredentialFields extends StatelessWidget {
  const LoginCredentialFields({
    super.key,
    required this.usernameController,
    required this.passwordController,
    required this.usernameFocus,
    required this.busy,
    required this.obscurePassword,
    required this.sideBySide,
    required this.onUsernameChanged,
    required this.onToggleObscure,
    required this.onSubmit,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final FocusNode usernameFocus;
  final bool busy;
  final bool obscurePassword;
  final bool sideBySide;
  final ValueChanged<String> onUsernameChanged;
  final VoidCallback onToggleObscure;
  final VoidCallback onSubmit;

  Widget _buildUsernameField() => TextFormField(
    controller: usernameController,
    focusNode: usernameFocus,
    enabled: !busy,
    textInputAction: TextInputAction.next,
    autocorrect: false,
    autofillHints: const [AutofillHints.username],
    onChanged: onUsernameChanged,
    decoration: const InputDecoration(
      isDense: true,
      labelText: '用户名',
      prefixIcon: Icon(Icons.person_outline_rounded, size: 19),
    ),
    validator: (v) => v == null || v.trim().isEmpty ? '请输入用户名' : null,
  );

  Widget _buildPasswordField() => TextFormField(
    controller: passwordController,
    enabled: !busy,
    obscureText: obscurePassword,
    textInputAction: TextInputAction.done,
    autofillHints: const [AutofillHints.password],
    decoration: InputDecoration(
      isDense: true,
      labelText: '密码',
      prefixIcon: const Icon(Icons.lock_outline_rounded, size: 19),
      suffixIcon: IconButton(
        tooltip: obscurePassword ? '显示密码' : '隐藏密码',
        visualDensity: VisualDensity.compact,
        onPressed: onToggleObscure,
        icon: Icon(
          obscurePassword
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          size: 19,
        ),
      ),
    ),
    validator: (v) => v == null || v.isEmpty ? '请输入密码' : null,
    onFieldSubmitted: (_) => onSubmit(),
  );

  @override
  Widget build(BuildContext context) {
    if (sideBySide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildUsernameField()),
          const SizedBox(width: 12),
          Expanded(child: _buildPasswordField()),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildUsernameField(),
        const SizedBox(height: 11),
        _buildPasswordField(),
      ],
    );
  }
}

/// Expandable HTTPS certificate pin and public plaintext HTTP allowlist controls.
class LoginConnectionSecuritySection extends StatelessWidget {
  const LoginConnectionSecuritySection({
    super.key,
    required this.normalizedServer,
    required this.fingerprintController,
    required this.allowedHttpOrigins,
    required this.expanded,
    required this.busy,
    required this.isHttpsServer,
    required this.onToggleExpanded,
    required this.onToggleCurrentHttpAllowlist,
    required this.onRemoveAllowedHttpOrigin,
  });

  final String normalizedServer;
  final TextEditingController fingerprintController;
  final Set<String> allowedHttpOrigins;
  final bool expanded;
  final bool busy;
  final bool isHttpsServer;
  final VoidCallback onToggleExpanded;
  final void Function(bool enable, String origin) onToggleCurrentHttpAllowlist;
  final ValueChanged<String> onRemoveAllowedHttpOrigin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final publicHttpOrigin =
        InsecureHttpAllowlist.requiresAllowlist(normalizedServer)
        ? InsecureHttpAllowlist.normalizeOrigin(normalizedServer)
        : null;
    final currentOriginAllowed =
        publicHttpOrigin != null &&
        allowedHttpOrigins.contains(publicHttpOrigin);
    final sortedAllowlist = allowedHttpOrigins.toList()..sort();
    final securityLabel = fingerprintController.text.isNotEmpty
        ? '连接安全设置 · 已记住证书指纹'
        : currentOriginAllowed
        ? '连接安全设置 · 已信任明文 HTTP'
        : sortedAllowlist.isNotEmpty
        ? '连接安全设置 · ${sortedAllowlist.length} 条 HTTP 白名单'
        : '连接安全设置';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              child: TextButton.icon(
                key: const Key('connectionSecurityToggle'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: const Size(0, 32),
                ),
                onPressed: busy ? null : onToggleExpanded,
                icon: Icon(
                  expanded ? Icons.expand_less : Icons.shield_outlined,
                  size: 16,
                ),
                label: Text(
                  securityLabel,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '首次连接指引',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: busy ? null : () => showLoginSetupGuideDialog(context),
              icon: Icon(
                Icons.help_outline_rounded,
                size: 17,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        IsleAnimatedExpand(
          expanded: expanded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              TextFormField(
                key: const Key('certificateFingerprint'),
                controller: fingerprintController,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'HTTPS 证书 SHA-256 指纹（可选）',
                  helperText: '仅自签名 HTTPS 首次连接需核对；受信任证书可留空。',
                  helperMaxLines: 3,
                  prefixIcon: Icon(Icons.verified_user_outlined, size: 19),
                ),
                validator: (value) {
                  final pin = (value ?? '').replaceAll(RegExp(r'[:\s]'), '');
                  if (pin.isEmpty) return null;
                  if (!isHttpsServer) {
                    return '证书指纹仅用于 HTTPS 地址';
                  }
                  return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(pin)
                      ? null
                      : '请输入完整的 64 位 SHA-256 指纹';
                },
              ),
              const SizedBox(height: 8),
              if (publicHttpOrigin != null)
                SwitchListTile.adaptive(
                  key: const Key('allowInsecureHttpOriginSwitch'),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                  value: currentOriginAllowed,
                  onChanged: busy
                      ? null
                      : (v) =>
                            onToggleCurrentHttpAllowlist(v, publicHttpOrigin),
                  title: const Text(
                    '允许此地址使用明文 HTTP',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '$publicHttpOrigin（风险自担：密码与会话不加密）',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              if (sortedAllowlist.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '本机明文 HTTP 白名单（精确 Origin）',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                for (final origin in sortedAllowlist)
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 14,
                        color: colors.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          origin,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        key: Key('removeHttpAllowlist_$origin'),
                        tooltip: '移出白名单',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: busy
                            ? null
                            : () => onRemoveAllowedHttpOrigin(origin),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ] else if (publicHttpOrigin == null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text(
                    '公网地址默认要求 HTTPS；输入公网 http:// 地址时，可在此按精确 Origin 加入本机白名单。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}
