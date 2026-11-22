import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/core.dart';

export 'package:xterm/core.dart' show TerminalLimitException;

final class ConsoleTerminalRow {
  const ConsoleTerminalRow(this.text, this.wrapped);
  final String text;
  final bool wrapped;
}

/// One bounded engine for both renderer and MCP, never a second transcript.
final class ConsoleTerminalEngine {
  ConsoleTerminalEngine({
    void Function(String)? onResponse,
    int maxScrollbackLines = 10000,
    int maxScrollbackBytes = 4194304,
  }) : _terminal = _ConsoleTerminal(onResponse) {
    terminal.mainBuffer
      ..maxScrollbackLines = maxScrollbackLines.clamp(0, 10000)
      ..maxScrollbackBytes = maxScrollbackBytes.clamp(1, 4194304);
    terminal.onResize = (_, __, ___, ____) {
      historyVersion++;
    };
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.from(_DecodedText(_write)));
  }
  final _ConsoleTerminal _terminal;
  Terminal get terminal => _terminal;
  ByteConversionSink? _decoder;
  int historyVersion = 1;
  bool get truncated => terminal.mainBuffer.truncated;
  bool get isAlt => terminal.isUsingAltBuffer;
  int get cursorX => terminal.buffer.cursorX;
  int get cursorY => terminal.buffer.cursorY;
  List<ConsoleTerminalRow> get scrollback => [
    for (var i = 0; i < terminal.mainBuffer.scrollBack; i++)
      _row(terminal.mainBuffer.lines[i]),
  ];
  List<ConsoleTerminalRow> get screen => [
    for (var i = terminal.buffer.scrollBack; i < terminal.buffer.height; i++)
      _row(terminal.buffer.lines[i]),
  ];
  ConsoleTerminalRow row(bool screen, int index) {
    final buffer = screen ? terminal.buffer : terminal.mainBuffer;
    final offset = screen ? buffer.scrollBack : 0;
    return _row(buffer.lines[index + offset]);
  }

  static ConsoleTerminalRow _row(BufferLine line) =>
      ConsoleTerminalRow(Buffer.plainText(line), line.isWrapped);

  void _write(String text) {
    if (text.isEmpty) return;
    try {
      terminal.write(text);
    } finally {
      // The parser may have changed rows before rejecting a suffix.
      historyVersion++;
    }
  }

  void feed(Uint8List bytes) {
    final decoder = _decoder;
    if (decoder == null) return;
    if (bytes.length > 1048576) throw const TerminalLimitException();
    for (var i = 0; i < bytes.length; i += 16384) {
      decoder.add(
        Uint8List.sublistView(bytes, i, (i + 16384).clamp(0, bytes.length)),
      );
    }
  }

  void finish() {
    final decoder = _decoder;
    _decoder = null;
    decoder?.close();
  }

  void freeze() {
    _terminal.frozen = true;
    _decoder = null;
    terminal
      ..onOutput = null
      ..onResponse = null;
  }

  void clear() {
    // Discard the in-memory decoder: closing it executes pending remote bytes.
    // A trust reset must never interpret more input or fail before clearing.
    terminal.clearOutput();
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.from(_DecodedText(_write)));
    historyVersion++;
  }

  void resize(int columns, int rows) {
    if (_terminal.frozen) return;
    terminal.resize(columns.clamp(2, 512), rows.clamp(1, 200));
    historyVersion++;
    terminal.notifyListeners();
  }

  Uint8List _encode(void Function() encode) {
    final output = StringBuffer();
    final previous = terminal.onOutput;
    terminal.onOutput = output.write;
    try {
      encode();
    } finally {
      terminal.onOutput = previous;
    }
    final result = Uint8List.fromList(utf8.encode(output.toString()));
    if (result.isEmpty || result.length > 65536) {
      throw const TerminalLimitException();
    }
    return result;
  }

  Uint8List encodeText(String text, {bool paste = true}) => _encode(() {
    if (paste) {
      terminal.paste(text);
    } else {
      terminal.textInput(text);
    }
  });

  Uint8List encodeKey(String name) => _encode(() {
    if (name.startsWith('Ctrl+') &&
        name.length == 6 &&
        name.codeUnitAt(5) >= 65 &&
        name.codeUnitAt(5) <= 90) {
      terminal.textInput(String.fromCharCode(name.codeUnitAt(5) - 64));
      return;
    }
    final key = switch (name) {
      'Enter' => TerminalKey.enter,
      'Backspace' => TerminalKey.backspace,
      'Tab' => TerminalKey.tab,
      'Escape' => TerminalKey.escape,
      'ArrowUp' => TerminalKey.arrowUp,
      'ArrowDown' => TerminalKey.arrowDown,
      'ArrowLeft' => TerminalKey.arrowLeft,
      'ArrowRight' => TerminalKey.arrowRight,
      'Home' => TerminalKey.home,
      'End' => TerminalKey.end,
      'Delete' => TerminalKey.delete,
      'PageUp' => TerminalKey.pageUp,
      'PageDown' => TerminalKey.pageDown,
      _ => throw ArgumentError('Unsupported terminal key'),
    };
    terminal.keyInput(key);
  });
}

/// An already attached renderer may still hold this model when it is archived.
final class _ConsoleTerminal extends Terminal {
  _ConsoleTerminal(void Function(String)? onResponse)
    : super(maxLines: 10200, onResponse: onResponse);

  bool frozen = false;

  @override
  void write(String data) {
    if (!frozen) super.write(data);
  }

  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    if (!frozen) {
      super.resize(newWidth, newHeight, pixelWidth, pixelHeight);
    }
  }
}

final class _DecodedText implements Sink<String> {
  const _DecodedText(this.write);
  final void Function(String) write;
  @override
  void add(String data) => write(data);
  @override
  void close() {}
}
