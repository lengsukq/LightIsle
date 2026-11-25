import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

class FamilyBoardMessage {
  const FamilyBoardMessage({
    required this.id,
    required this.authorUserId,
    required this.authorUsername,
    required this.authorRole,
    required this.content,
    required this.tag,
    required this.color,
    required this.pinned,
    required this.pinnedAt,
    required this.pinnedBy,
    required this.createdAt,
  });

  final int id;
  final int authorUserId;
  final String authorUsername;
  final String authorRole;
  final String content;
  final String tag;
  final String color;
  final bool pinned;
  final int pinnedAt;
  final String pinnedBy;
  final int createdAt;

  factory FamilyBoardMessage.fromJson(Map<String, dynamic> json) {
    return FamilyBoardMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      authorUserId: (json['authorUserId'] as num?)?.toInt() ?? 0,
      authorUsername: json['authorUsername']?.toString() ?? '',
      authorRole: json['authorRole']?.toString() ?? 'member',
      content: json['content']?.toString() ?? '',
      tag: json['tag']?.toString() ?? '留言',
      color: json['color']?.toString() ?? 'amber',
      pinned: json['pinned'] == true,
      pinnedAt: (json['pinnedAt'] as num?)?.toInt() ?? 0,
      pinnedBy: json['pinnedBy']?.toString() ?? '',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class FamilyBoardSection extends StatefulWidget {
  const FamilyBoardSection({
    super.key,
    required this.api,
    required this.isAdmin,
  });

  final LightIsleApi api;
  final bool isAdmin;

  @override
  State<FamilyBoardSection> createState() => _FamilyBoardSectionState();
}

class _FamilyBoardSectionState extends State<FamilyBoardSection> {
  static const List<String> _tags = ['留言', '提醒', '采购', '心愿'];
  static const List<({String id, String label, Color color})> _colors = [
    (id: 'amber', label: '暖阳', color: Color(0xFFE8A64D)),
    (id: 'blue', label: '晴空', color: Color(0xFF0E6B74)),
    (id: 'rose', label: '晚霞', color: Color(0xFFD4657D)),
    (id: 'sage', label: '青苔', color: Color(0xFF18835B)),
    (id: 'violet', label: '暮紫', color: Color(0xFF6B5799)),
  ];

  late final PageController _pageController;
  List<FamilyBoardMessage> _messages = const [];
  int _currentUserId = 0;
  int _activeIndex = 0;
  bool _loading = false;
  int? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.92);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FamilyBoardSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.isAdmin != widget.isAdmin) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load({int? focusMessageId}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.get(
        '/api/v2/board/messages',
        query: const {'limit': '50'},
      );
      final rawList = objectList(res['messages']);
      final next = rawList
          .map(FamilyBoardMessage.fromJson)
          .where((m) => m.id > 0)
          .toList(growable: false);
      final uid = (res['currentUserId'] as num?)?.toInt() ?? _currentUserId;
      if (!mounted) return;
      var targetIdx = _activeIndex;
      if (focusMessageId != null) {
        final found = next.indexWhere((m) => m.id == focusMessageId);
        targetIdx = found >= 0 ? found : 0;
      } else if (targetIdx >= next.length) {
        targetIdx = next.isEmpty ? 0 : next.length - 1;
      }
      setState(() {
        _messages = next;
        _currentUserId = uid;
        _activeIndex = targetIdx;
        _loading = false;
      });
      if (next.isNotEmpty && _pageController.hasClients) {
        final reduced = IsleMotion.reducedMotion(context);
        if (reduced) {
          _pageController.jumpToPage(targetIdx);
        } else {
          unawaited(
            _pageController.animateToPage(
              targetIdx,
              duration: IsleMotion.navigation,
              curve: IsleMotion.curve,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(e);
        _loading = false;
      });
    }
  }

  bool _canDelete(FamilyBoardMessage msg) =>
      widget.isAdmin || (_currentUserId > 0 && msg.authorUserId == _currentUserId);

  Color _toneColor(String id) {
    for (final c in _colors) {
      if (c.id == id) return c.color;
    }
    return _colors.first.color;
  }

  String _formatTime(int unixSec) {
    if (unixSec <= 0) return '';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final diff = nowSec - unixSec;
    if (diff < 60) return '刚刚';
    if (diff < 3600) return '${diff ~/ 60} 分钟前';
    if (diff < 86400) return '${diff ~/ 3600} 小时前';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000).toLocal();
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$mi';
  }

  Future<void> _togglePin(FamilyBoardMessage msg) async {
    if (!widget.isAdmin || _busyId != null) return;
    setState(() => _busyId = msg.id);
    try {
      await widget.api.send(
        'PATCH',
        '/api/v2/board/messages/${msg.id}/pin',
        body: {'pinned': !msg.pinned},
      );
      if (mounted) {
        await _load(focusMessageId: msg.id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('更新置顶状态失败：${userFacingError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteMessage(FamilyBoardMessage msg) async {
    if (!_canDelete(msg) || _busyId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条留言？'),
        content: const Text('删除后家庭成员将不再看到此留言。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyId = msg.id);
    try {
      await widget.api.send('DELETE', '/api/v2/board/messages/${msg.id}');
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('删除失败：${userFacingError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _openComposer() async {
    final controller = TextEditingController();
    var selectedTag = _tags.first;
    var selectedColor = _colors.first.id;
    var submitting = false;
    String? submitError;

    final createdId = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, bottomInset + 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        '写一条家庭留言',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: submitting ? null : () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in _tags)
                        ChoiceChip(
                          label: Text(tag),
                          selected: selectedTag == tag,
                          onSelected: submitting
                              ? null
                              : (_) => setSheetState(() => selectedTag = tag),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        '卡片色调',
                        style: Theme.of(ctx).textTheme.labelMedium,
                      ),
                      const SizedBox(width: 10),
                      for (final c in _colors)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: submitting
                                ? null
                                : () => setSheetState(() => selectedColor = c.id),
                            child: AnimatedContainer(
                              duration: IsleMotion.fast,
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: c.color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selectedColor == c.id
                                      ? Theme.of(ctx).colorScheme.onSurface
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    maxLength: 500,
                    maxLines: 4,
                    minLines: 3,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '今晚想吃什么、顺路买点东西，或者周末安排…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (submitError != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      submitError!,
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: submitting
                        ? null
                        : () async {
                            final text = controller.text.trim();
                            if (text.isEmpty) {
                              setSheetState(() => submitError = '请输入留言内容');
                              return;
                            }
                            setSheetState(() {
                              submitting = true;
                              submitError = null;
                            });
                            try {
                              final res = await widget.api.send(
                                'POST',
                                '/api/v2/board/messages',
                                body: {
                                  'content': text,
                                  'tag': selectedTag,
                                  'color': selectedColor,
                                },
                              );
                              final msg = res['message'];
                              final id = msg is Map
                                  ? (msg['id'] as num?)?.toInt()
                                  : null;
                              if (ctx.mounted) Navigator.of(ctx).pop(id ?? -1);
                            } catch (e) {
                              setSheetState(() {
                                submitting = false;
                                submitError = userFacingError(e);
                              });
                            }
                          },
                    icon: const Icon(Icons.send_rounded, size: 17),
                    label: Text(submitting ? '发布中…' : '发布留言'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    controller.dispose();
    if (createdId != null && mounted) {
      await _load(focusMessageId: createdId > 0 ? createdId : null);
    }
  }

  Widget _buildMessageCard(
    BuildContext context,
    FamilyBoardMessage msg,
    bool dark,
    IslePalette palette,
  ) {
    final tone = _toneColor(msg.color);
    final avatarChar = msg.authorUsername.trim().isEmpty
        ? '家'
        : msg.authorUsername.trim().substring(0, 1).toUpperCase();
    final isBusy = _busyId == msg.id;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      decoration: BoxDecoration(
        gradient: IsleGlass.embossedGradient(dark, palette, tint: tone),
        borderRadius: BorderRadius.circular(IsleRadius.card),
        border: Border.all(
          color: msg.pinned
              ? const Color(0xFFD4891C).withValues(alpha: dark ? 0.58 : 0.45)
              : IsleGlass.rimBorderColor(dark),
          width: msg.pinned ? 1.25 : 0.9,
        ),
        boxShadow: IsleShadows.card(dark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: dark ? 0.26 : 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Text(
                  avatarChar,
                  style: TextStyle(
                    color: tone,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            msg.authorUsername,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: tone.withValues(alpha: dark ? 0.24 : 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            msg.tag,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: tone,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${msg.authorRole == 'admin' ? '管理员' : '家人'} · ${_formatTime(msg.createdAt)}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: palette['textTertiary'],
                      ),
                    ),
                  ],
                ),
              ),
              if (msg.pinned)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4891C).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.push_pin_rounded,
                        size: 12,
                        color: Color(0xFFB46A06),
                      ),
                      SizedBox(width: 3),
                      Text(
                        '置顶',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFB46A06),
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.isAdmin)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: msg.pinned ? '取消置顶' : '置顶此留言',
                  onPressed: isBusy ? null : () => unawaited(_togglePin(msg)),
                  icon: Icon(
                    msg.pinned
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                    size: 18,
                    color: msg.pinned
                        ? const Color(0xFFD4891C)
                        : palette['textSecondary'],
                  ),
                ),
              if (_canDelete(msg))
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '删除留言',
                  onPressed: isBusy ? null : () => unawaited(_deleteMessage(msg)),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: palette['textSecondary'],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Text(
                msg.content,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.55,
                  color: palette['textPrimary'],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _messages.length > 1 ? '左右滑动切换留言' : '最新家庭留言',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: palette['textTertiary'],
                ),
              ),
              const Spacer(),
              if (msg.pinned && msg.pinnedBy.isNotEmpty)
                Text(
                  '由 ${msg.pinnedBy} 置顶',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: const Color(0xFFB46A06),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final reduced = IsleMotion.reducedMotion(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '家庭留言板',
          accentColor: palette['brandAmber'],
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_messages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '${_activeIndex + 1} / ${_messages.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette['textTertiary'],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              TextButton.icon(
                onPressed: _openComposer,
                icon: const Icon(Icons.edit_note_rounded, size: 17),
                label: const Text('写留言'),
              ),
            ],
          ),
        ),
        if (_messages.isNotEmpty) ...[
          SizedBox(
            height: 196,
            child: PageView.builder(
              controller: _pageController,
              physics: const BouncingScrollPhysics(),
              itemCount: _messages.length,
              onPageChanged: (index) {
                if (_activeIndex != index) {
                  setState(() => _activeIndex = index);
                }
              },
              itemBuilder: (context, index) {
                final card = _buildMessageCard(
                  context,
                  _messages[index],
                  dark,
                  palette,
                );
                if (reduced) return card;
                return AnimatedBuilder(
                  animation: _pageController,
                  child: card,
                  builder: (context, child) {
                    var page = _activeIndex.toDouble();
                    if (_pageController.hasClients &&
                        _pageController.position.haveDimensions) {
                      page = _pageController.page ?? page;
                    }
                    final delta = (page - index).abs().clamp(0.0, 1.0);
                    final scale = lerpDouble(1.0, 0.93, delta) ?? 1.0;
                    final opacity = lerpDouble(1.0, 0.74, delta) ?? 1.0;
                    final dy = lerpDouble(0.0, 8.0, delta) ?? 0.0;
                    return Transform.translate(
                      offset: Offset(0, dy),
                      child: Transform.scale(
                        scale: scale,
                        child: Opacity(opacity: opacity, child: child),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_messages.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _messages.length && i < 12; i++)
                    GestureDetector(
                      onTap: () {
                        if (reduced) {
                          _pageController.jumpToPage(i);
                        } else {
                          unawaited(
                            _pageController.animateToPage(
                              i,
                              duration: IsleMotion.navigation,
                              curve: IsleMotion.curve,
                            ),
                          );
                        }
                      },
                      child: AnimatedContainer(
                        duration: reduced ? Duration.zero : IsleMotion.fast,
                        curve: IsleMotion.curve,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == _activeIndex ? 22 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: i == _activeIndex
                              ? (_messages[i].pinned
                                    ? const Color(0xFFD4891C)
                                    : palette['accentPrimary'])
                              : (_messages[i].pinned
                                    ? const Color(0xFFD4891C).withValues(alpha: 0.45)
                                    : palette['textDisabled']),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ] else if (!_loading) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: palette['cardItemTop'],
              borderRadius: BorderRadius.circular(IsleRadius.card),
              border: Border.all(color: IsleGlass.rimBorderColor(dark)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.forum_outlined,
                  color: palette['brandAmber'],
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '还没有家庭留言',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _error ?? '写下第一条留言，家人打开首页左右滑动即可翻看。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette['textTertiary'],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _openComposer,
                  child: const Text('写第一条'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
