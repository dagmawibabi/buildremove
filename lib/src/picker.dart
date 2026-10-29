import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'util.dart';

class PickResult {
  PickResult(this.selected, this.ignored);
  final Set<int> selected;
  final Set<int> ignored;
}

// Windows console input modes.
const _processedInput = 0x0001;
const _lineInput = 0x0002;
const _echoInput = 0x0004;
const _virtualTerminalInput = 0x0200;

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _getStdHandle = _kernel32
    .lookupFunction<IntPtr Function(Int32), int Function(int)>('GetStdHandle');
final _getConsoleMode = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetConsoleMode');
final _setConsoleMode = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
      'SetConsoleMode',
    );

/// Puts the terminal into key-at-a-time mode and back.
class _RawMode {
  int? _windowsMode;

  bool enter() {
    if (!stdin.hasTerminal ||
        !stdout.hasTerminal ||
        !stdout.supportsAnsiEscapes) {
      return false;
    }
    try {
      if (Platform.isWindows) {
        final handle = _getStdHandle(-10); // STD_INPUT_HANDLE
        final mode = calloc<Uint32>();
        try {
          if (_getConsoleMode(handle, mode) == 0) return false;
          _windowsMode = mode.value;
        } finally {
          calloc.free(mode);
        }
        // Arrow keys as VT escape sequences; Ctrl+C as a byte we handle.
        final raw =
            (_windowsMode! | _virtualTerminalInput) &
            ~(_processedInput | _lineInput | _echoInput);
        return _setConsoleMode(handle, raw) != 0;
      }
      stdin.echoMode = false;
      stdin.lineMode = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  void exit() {
    try {
      if (Platform.isWindows) {
        if (_windowsMode != null) {
          _setConsoleMode(_getStdHandle(-10), _windowsMode!);
        }
      } else {
        stdin.lineMode = true;
        stdin.echoMode = true;
      }
    } catch (_) {}
  }
}

enum _Key {
  up,
  down,
  pageUp,
  pageDown,
  home,
  end,
  space,
  enter,
  interrupt,
  char,
  none,
}

(_Key, String) _readKey() {
  final b = stdin.readByteSync();
  switch (b) {
    case -1:
      return (_Key.interrupt, '');
    case 3:
      return (_Key.interrupt, '');
    case 10 || 13:
      return (_Key.enter, '');
    case 32:
      return (_Key.space, '');
    case 27:
      final b2 = stdin.readByteSync();
      if (b2 != 91 && b2 != 79) return (_Key.none, '');
      final b3 = stdin.readByteSync();
      switch (b3) {
        case 65:
          return (_Key.up, '');
        case 66:
          return (_Key.down, '');
        case 72:
          return (_Key.home, '');
        case 70:
          return (_Key.end, '');
        case 49 || 52 || 53 || 54:
          stdin.readByteSync(); // trailing '~'
          return (
            switch (b3) {
              49 => _Key.home,
              52 => _Key.end,
              53 => _Key.pageUp,
              _ => _Key.pageDown,
            },
            '',
          );
      }
      return (_Key.none, '');
    case 0 || 224:
      // Legacy Windows console scan codes.
      return (
        switch (stdin.readByteSync()) {
          72 => _Key.up,
          80 => _Key.down,
          73 => _Key.pageUp,
          81 => _Key.pageDown,
          71 => _Key.home,
          79 => _Key.end,
          _ => _Key.none,
        },
        '',
      );
  }
  return (_Key.char, String.fromCharCode(b).toLowerCase());
}

/// Checkbox list driven by arrow keys. Returns null when the terminal can't
/// do raw input, so callers can fall back to typed numbers.
///
/// [suggested] items can be toggled together with "u"; [allowIgnore] adds an
/// "i" key that marks items as ignored. With [enterPicksCurrent], Enter on an
/// empty selection picks the highlighted item.
PickResult? pickMany(
  String title,
  List<String> lines, {
  String? header,
  Set<int> initial = const {},
  Set<int> suggested = const {},
  bool allowIgnore = false,
  bool enterPicksCurrent = false,
  String Function(Set<int> selected)? summary,
}) {
  if (lines.isEmpty) return PickResult({}, {});
  final raw = _RawMode();
  if (!raw.enter()) return null;

  final n = lines.length;
  final selected = {...initial};
  final ignored = <int>{};
  var cursor = 0;
  var top = 0;
  var drawn = 0;
  final help = [
    '↑/↓ move',
    'space select',
    'a all',
    if (suggested.isNotEmpty) 'u unused',
    if (allowIgnore) 'i ignore',
    'enter done',
    'q cancel',
  ].join(' · ');

  int pageSize() => max(3, stdout.terminalLines - 7);

  void erase() {
    if (drawn > 0) stdout.write('\x1B[${drawn}A\r\x1B[J');
    drawn = 0;
  }

  void draw() {
    final width = max(20, stdout.terminalColumns - 1);
    final visible = min(n, pageSize());
    if (cursor < top) top = cursor;
    if (cursor >= top + visible) top = cursor - visible + 1;

    final rows = <String>[
      bold(fit(title, width)),
      dim(fit(help, width)),
      if (header != null) dim(fit('      $header', width)),
    ];
    for (var i = top; i < top + visible; i++) {
      final mark = ignored.contains(i)
          ? '[-]'
          : selected.contains(i)
          ? '[x]'
          : '[ ]';
      final text = fit('${i == cursor ? '›' : ' '} $mark ${lines[i]}', width);
      rows.add(
        i == cursor
            ? cyan(text)
            : ignored.contains(i)
            ? dim(text)
            : selected.contains(i)
            ? green(text)
            : text,
      );
    }
    final range = n > visible ? '   (${top + 1}-${top + visible} of $n)' : '';
    final info = summary?.call(selected) ?? '${selected.length} selected';
    rows.add(dim(fit('$info$range', width)));

    final out = StringBuffer();
    if (drawn > 0) out.write('\x1B[${drawn}A');
    out.write('\r\x1B[J');
    out.writeln(rows.join('\n'));
    stdout.write(out);
    drawn = rows.length;
  }

  stdout.write('\x1B[?25l'); // hide cursor
  try {
    draw();
    while (true) {
      final (key, ch) = _readKey();
      switch (key) {
        case _Key.up:
          cursor = (cursor - 1 + n) % n;
        case _Key.down:
          cursor = (cursor + 1) % n;
        case _Key.pageUp:
          cursor = max(0, cursor - pageSize());
        case _Key.pageDown:
          cursor = min(n - 1, cursor + pageSize());
        case _Key.home:
          cursor = 0;
        case _Key.end:
          cursor = n - 1;
        case _Key.space:
          if (!ignored.contains(cursor) && !selected.remove(cursor)) {
            selected.add(cursor);
          }
        case _Key.enter:
          if (selected.isEmpty &&
              enterPicksCurrent &&
              !ignored.contains(cursor)) {
            selected.add(cursor);
          }
          erase();
          stdout.writeln(
            '${green('✓')} ${bold(title)} ${dim(summary?.call(selected) ?? '${selected.length} selected')}',
          );
          return PickResult(selected, ignored);
        case _Key.interrupt:
          erase();
          raw.exit();
          stdout.write('\x1B[?25h');
          exit(130);
        case _Key.char:
          switch (ch) {
            case 'k' || 'w':
              cursor = (cursor - 1 + n) % n;
            case 'j' || 's':
              cursor = (cursor + 1) % n;
            case 'a':
              final all = {
                for (var i = 0; i < n; i++)
                  if (!ignored.contains(i)) i,
              };
              if (selected.containsAll(all)) {
                selected.clear();
              } else {
                selected.addAll(all);
              }
            case 'u' when suggested.isNotEmpty:
              final pick = suggested.difference(ignored);
              if (selected.containsAll(pick)) {
                selected.removeAll(pick);
              } else {
                selected.addAll(pick);
              }
            case 'i' when allowIgnore:
              if (!ignored.remove(cursor)) {
                ignored.add(cursor);
                selected.remove(cursor);
              }
            case 'q':
              erase();
              stdout.writeln('${dim('✗')} ${bold(title)} ${dim('cancelled')}');
              return PickResult({}, ignored);
          }
        case _Key.none:
          break;
      }
      draw();
    }
  } finally {
    raw.exit();
    stdout.write('\x1B[?25h'); // show cursor
  }
}
