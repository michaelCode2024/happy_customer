/// Presentation helpers shared by every screen.
///
/// Dates arrive from the server in UTC and are converted to local time in the
/// models, so everything here works on local [DateTime]s.
library;

/// A short, human "when" for a list row: `刚刚`, `12:04`, `昨天`, `3月5日`.
///
/// A conversation queue is scanned, not read: the agent needs to know whether a
/// thread is hot right now, and an absolute timestamp makes that harder, not
/// easier.
String relativeTime(DateTime? value, {DateTime? now}) {
  if (value == null) {
    return '';
  }
  final reference = now ?? DateTime.now();
  final difference = reference.difference(value);
  if (difference.inSeconds < 60) {
    return '刚刚';
  }
  if (difference.inMinutes < 60) {
    return '${difference.inMinutes} 分钟前';
  }
  final sameDay = value.year == reference.year &&
      value.month == reference.month &&
      value.day == reference.day;
  if (sameDay) {
    return clockTime(value);
  }
  final yesterday = reference.subtract(const Duration(days: 1));
  if (value.year == yesterday.year &&
      value.month == yesterday.month &&
      value.day == yesterday.day) {
    return '昨天 ${clockTime(value)}';
  }
  if (value.year == reference.year) {
    return '${value.month}月${value.day}日';
  }
  return '${value.year}/${value.month}/${value.day}';
}

/// `HH:mm`, zero padded, in 24-hour form.
String clockTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

/// `3月5日 14:20`, for tooltips and profile rows where precision matters.
String fullTime(DateTime? value) {
  if (value == null) {
    return '—';
  }
  return '${value.month}月${value.day}日 ${clockTime(value)}';
}

/// A day separator label above the first message of each day.
String dayLabel(DateTime value, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final day = DateTime(value.year, value.month, value.day);
  final delta = today.difference(day).inDays;
  if (delta == 0) {
    return '今天';
  }
  if (delta == 1) {
    return '昨天';
  }
  if (delta < 7) {
    return '$delta 天前';
  }
  if (value.year == reference.year) {
    return '${value.month}月${value.day}日';
  }
  return '${value.year}年${value.month}月${value.day}日';
}

/// Turns a second count into a compact duration: `48秒`, `3分12秒`, `1.4小时`.
///
/// The first-response metric is read at a glance and compared between days, so
/// the unit is chosen by magnitude rather than always printing seconds.
String durationText(num seconds) {
  if (seconds <= 0) {
    return '—';
  }
  if (seconds < 60) {
    return '${seconds.round()} 秒';
  }
  if (seconds < 3600) {
    final minutes = seconds ~/ 60;
    final rest = (seconds % 60).round();
    return rest == 0 ? '$minutes 分钟' : '$minutes 分 $rest 秒';
  }
  return '${(seconds / 3600).toStringAsFixed(1)} 小时';
}

/// `82.5%`, for rates that arrive as 0..1.
String percentText(double ratio) {
  if (ratio <= 0) {
    return '0%';
  }
  return '${(ratio * 100).toStringAsFixed(1)}%';
}

/// `1.2 万` style abbreviation, so a big counter still fits in a card.
String compactCount(int value) {
  if (value < 10000) {
    return '$value';
  }
  return '${(value / 10000).toStringAsFixed(1)} 万';
}

/// The initials shown in a round avatar. Chinese names contribute one character;
/// latin names contribute two letters, which is what reads best at 32px.
///
/// Implemented over runes rather than the `characters` package so this file has
/// no dependency of its own: the inputs are names, and a grapheme cluster of
/// more than one code point is not something a display name relies on.
String initials(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return '?';
  }
  final runes = trimmed.runes.toList(growable: false);
  // CJK, kana and hangul all start above 0x2E80: one glyph is the whole name.
  if (runes.first > 0x2E80) {
    return String.fromCharCode(runes.first);
  }
  final parts = trimmed
      .split(RegExp(r'[\s._-]+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.length >= 2) {
    return '${_firstGlyph(parts[0])}${_firstGlyph(parts[1])}'.toUpperCase();
  }
  final take = runes.length >= 2 ? 2 : 1;
  return String.fromCharCodes(runes.take(take)).toUpperCase();
}

String _firstGlyph(String value) {
  final runes = value.runes;
  return runes.isEmpty ? '' : String.fromCharCode(runes.first);
}

/// A stable colour per identity, so an agent's avatar is the same everywhere
/// without the server having to store one.
int avatarHue(String seed) {
  if (seed.isEmpty) {
    return 210;
  }
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7FFFFFFF;
  }
  return hash % 360;
}

/// Shortens an id for display in debug rows: `8f3c…41ab`.
String shortId(String value) {
  if (value.length <= 12) {
    return value;
  }
  return '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
}

/// A file size for an attachment bubble.
String fileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
