import 'dart:io';

import 'util.dart';

String ask(String question, {String? defaultValue}) {
  final hint = defaultValue == null ? '' : dim(' [$defaultValue]');
  final leading = RegExp(r'^\n*').stringMatch(question)!;
  stdout.write(
    '$leading${cyan('?')} ${question.substring(leading.length)}$hint ',
  );
  String? line;
  try {
    line = stdin.readLineSync();
  } on StdinException {
    line = null;
  }
  if (line == null) {
    // stdin closed (Ctrl+Z / piped input ran out) or not readable.
    stdout.writeln();
    exit(0);
  }
  // PowerShell pipes can prefix a byte-order mark.
  final answer = line
      .replaceAll(String.fromCharCode(0xFEFF), '')
      .replaceAll('ï»¿', '') // the same mark, decoded as Latin-1
      .trim();
  return answer.isEmpty ? (defaultValue ?? '') : answer;
}

bool confirm(String question, {bool defaultYes = false}) {
  final answer = ask(
    '$question ${dim(defaultYes ? '(Y/n)' : '(y/N)')}',
  ).toLowerCase();
  if (answer.isEmpty) return defaultYes;
  return answer == 'y' || answer == 'yes';
}

/// Parses "1,3,5-8", "all" or "none" into zero-based indexes below [count].
/// Returns null when the input is not understood.
Set<int>? parseSelection(String input, int count) {
  final text = input.trim().toLowerCase();
  if (text == 'all' || text == 'a' || text == '*') {
    return {for (var i = 0; i < count; i++) i};
  }
  if (text.isEmpty || text == 'none' || text == 'n') return {};
  final result = <int>{};
  for (final part in text.split(RegExp(r'[,\s]+'))) {
    if (part.isEmpty) continue;
    final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(part);
    if (range != null) {
      var a = int.parse(range.group(1)!);
      var b = int.parse(range.group(2)!);
      if (a > b) (a, b) = (b, a);
      if (a < 1 || b > count) return null;
      for (var i = a; i <= b; i++) {
        result.add(i - 1);
      }
      continue;
    }
    final n = int.tryParse(part);
    if (n == null || n < 1 || n > count) return null;
    result.add(n - 1);
  }
  return result;
}

/// Asks until the user enters a valid selection of items 1..[count].
Set<int> askSelection(
  String question,
  int count, {
  String defaultValue = 'all',
}) {
  while (true) {
    final sel = parseSelection(
      ask(question, defaultValue: defaultValue),
      count,
    );
    if (sel != null) return sel;
    stdout.writeln(red('  Use numbers like 1,3,5-8, or "all" / "none".'));
  }
}
