import 'dart:convert';

/// Shell that the SSH server runs exec-channel commands in.
///
/// Windows OpenSSH runs commands in cmd.exe by default, or in the shell set by
/// the `DefaultShell` registry value (usually PowerShell). Neither has bash,
/// which MuxPod pins for its ephemeral and persistent channels. Windows hosts
/// with a tmux port such as psmux get PowerShell channels instead, and the
/// POSIX command lines MuxPod builds are translated by [PowerShellCommand].
enum RemoteShell {
  /// sh, bash, zsh, fish and other Unix shells (the default)
  posix,

  /// Windows PowerShell or PowerShell 7 as the OpenSSH DefaultShell
  powershell,

  /// cmd.exe (Windows OpenSSH without DefaultShell)
  cmd;

  bool get isWindows => this != RemoteShell.posix;

  /// Command that identifies the shell from its stdout (see [fromProbe]).
  ///
  /// - Unix shells print `%OS%`. `$PSVersionTable` expands to nothing and
  ///   the rest fails on stderr (fish fails on the whole line).
  /// - PowerShell prints `%OS%` and then its major version.
  /// - cmd.exe expands `%OS%` and echoes the rest of the line verbatim.
  static const String probeCommand =
      r'echo %OS%;$PSVersionTable.PSVersion.Major';

  static RemoteShell fromProbe(String stdout) {
    final lines = const LineSplitter()
        .convert(stdout)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return RemoteShell.posix;
    if (lines.first.startsWith('Windows_NT')) return RemoteShell.cmd;
    if (lines.length >= 2 &&
        lines.first == '%OS%' &&
        RegExp(r'^\d+$').hasMatch(lines[1])) {
      return RemoteShell.powershell;
    }
    return RemoteShell.posix;
  }
}

/// Error for a POSIX command line that [PowerShellCommand] cannot translate.
class UnsupportedShellSyntaxError implements Exception {
  final String message;

  UnsupportedShellSyntaxError(this.message);

  @override
  String toString() => 'UnsupportedShellSyntaxError: $message';
}

/// Translates the POSIX command lines MuxPod builds into PowerShell.
///
/// Supported subset:
/// - words in single quotes, double quotes, `$'...'` (ANSI-C) and with
///   backslash escapes (`\;` is the literal word `;`)
/// - the separators `;`, `&&` and `||`, and the redirections `2>/dev/null`
///   and `2>&1`
/// - pipelines whose stages before the last are `printf`, `echo` or
///   `base64 -d`. Their output is computed here and becomes the last
///   stage's stdin (MuxPod's paste command).
/// - the builtins `echo`, `printf`, `test -e|-f|-x`, `command -v`,
///   `$SHELL -lc <script>` and `trap` (a no-op, PowerShell has no
///   equivalent for a dropped channel)
///
/// Every other command, `tmux` included, runs through `__mpx`, which starts
/// the program with System.Diagnostics.Process and copies its stdout and
/// stderr byte for byte. That avoids two PowerShell problems: Windows
/// PowerShell 5.1 does not escape embedded double quotes when it builds a
/// native command line, and PowerShell re-encodes native output in the
/// console code page. The argument line is quoted for CommandLineToArgvW,
/// which psmux (Rust) and other Windows programs parse.
class PowerShellCommand {
  PowerShellCommand._();

  /// Helper functions every translated script relies on.
  ///
  /// - `__mpo <text>` writes text to stdout as UTF-8, without a newline.
  /// - `__mpw <text>` writes text plus LF.
  /// - `__mpx <file> <args> <stderr> [<stdin base64>]` runs a program.
  ///   `<stderr>` is 0 to pass stderr through, 1 to drop it, 2 to append it
  ///   to stdout. Exit code 127 means the program did not start.
  /// - `__mpc <name>` prints the path of a program on PATH (`command -v`).
  /// - `__mpt <path>` tests that a file exists (`test -x`).
  ///
  /// All of them set `$LASTEXITCODE`.
  static const String preamble =
      r'function __mpo($s){$b=[Text.Encoding]::UTF8.GetBytes("$s");'
      r'$o=[Console]::OpenStandardOutput();$o.Write($b,0,$b.Length);$o.Flush();'
      r'$global:LASTEXITCODE=0};'
      r'function __mpw($s){__mpo "$s`n"};'
      r'function __mpx($f,$a,$r,$in){'
      r'$i=New-Object Diagnostics.ProcessStartInfo $f,$a;'
      r'$i.UseShellExecute=$false;$i.CreateNoWindow=$true;'
      r'$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true;'
      r'$i.RedirectStandardInput=($null -ne $in);'
      r'try{$p=[Diagnostics.Process]::Start($i)}catch{'
      r'$b=[Text.Encoding]::UTF8.GetBytes("$f`: $($_.Exception.InnerException.Message)`n");'
      r'[Console]::OpenStandardError().Write($b,0,$b.Length);'
      r'$global:LASTEXITCODE=127;return};'
      r'if($null -ne $in){$d=[Convert]::FromBase64String($in);'
      r'$p.StandardInput.BaseStream.Write($d,0,$d.Length);$p.StandardInput.Close()};'
      r'$m=New-Object IO.MemoryStream;'
      r'$t=$p.StandardError.BaseStream.CopyToAsync($m);'
      r'$o=[Console]::OpenStandardOutput();'
      r'$p.StandardOutput.BaseStream.CopyTo($o);$p.WaitForExit();$t.Wait();'
      r'if($r -eq 2){$m.WriteTo($o)}elseif($r -eq 0){$m.WriteTo([Console]::OpenStandardError())};'
      r'$o.Flush();$global:LASTEXITCODE=$p.ExitCode};'
      r'function __mpc($n){$c=Get-Command $n -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;'
      r'if($c){__mpw $c.Source}else{$global:LASTEXITCODE=1}};'
      r'function __mpt($p){$global:LASTEXITCODE=[int](-not(Test-Path -LiteralPath $p -PathType Leaf))}';

  /// Command that starts a PowerShell reading one script per stdin line.
  ///
  /// Used for every channel to a Windows host. Without a PTY, PowerShell
  /// neither echoes input nor prints prompts. The script arrives on stdin, so
  /// neither sshd nor the login shell parses its quotes. It works from
  /// cmd.exe and from PowerShell. A PowerShell login shell reduces a native
  /// command's exit code to 0 or 1, so it gets told to pass it on.
  static String shellCommand(RemoteShell shell) {
    const command = 'powershell -NoLogo -NoProfile -NonInteractive -Command -';
    return shell == RemoteShell.powershell
        ? '$command; exit \$LASTEXITCODE'
        : command;
  }

  /// Translates [command] into a single-line PowerShell script.
  ///
  /// The result needs [preamble] to have run in the same session.
  static String translate(String command) {
    final out = StringBuffer();
    for (final step in _parse(command)) {
      switch (step.separator) {
        case null:
          break;
        case ';':
          out.write(';');
        case '&&':
          out.write(r';if($LASTEXITCODE -eq 0){');
        case '||':
          out.write(r';if($LASTEXITCODE -ne 0){');
      }
      out.write(_emitPipeline(step.stages));
      if (step.separator == '&&' || step.separator == '||') out.write('}');
    }
    return out.toString();
  }

  /// PowerShell expression for the string [value].
  ///
  /// Single-quoted, so nothing inside expands. Control characters (ESC in
  /// key sequences, SOH in MuxPod's markers) are appended as `[char]N`,
  /// which keeps the script on one line. So is everything outside ASCII:
  /// PowerShell decodes stdin in the console code page, not UTF-8.
  static String literal(String value) {
    final parts = <String>[];
    final text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      final escaped = text.toString().replaceAllMapped(
        RegExp("['‘’‚‛]"),
        (m) => '${m[0]}${m[0]}',
      );
      parts.add("'$escaped'");
      text.clear();
    }

    for (final rune in value.runes) {
      if (rune < 0x20 || rune >= 0x7f) {
        flushText();
        parts.add(
          rune > 0xffff ? '[char]::ConvertFromUtf32($rune)' : '[char]$rune',
        );
      } else {
        text.writeCharCode(rune);
      }
    }
    flushText();
    if (parts.isEmpty) return "''";
    if (parts.length == 1 && !parts.first.startsWith('[')) return parts.first;
    return "(''+${parts.join('+')})";
  }

  /// Quotes [arg] the way CommandLineToArgvW reads it back.
  static String windowsArg(String arg) {
    if (arg.isNotEmpty && !arg.contains(RegExp(r'[\s"]'))) return arg;
    final out = StringBuffer('"');
    var backslashes = 0;
    for (final rune in arg.runes) {
      if (rune == 0x5c) {
        backslashes++;
        continue;
      }
      if (rune == 0x22) {
        out.write(r'\' * (backslashes * 2 + 1));
      } else {
        out.write(r'\' * backslashes);
      }
      backslashes = 0;
      out.writeCharCode(rune);
    }
    out
      ..write(r'\' * (backslashes * 2))
      ..write('"');
    return out.toString();
  }

  /// Output of `printf FORMAT ARGS...` (escapes and `%s`, `%d`, `%%`).
  static String printf(String format, List<String> args) {
    final out = StringBuffer();
    var argIndex = 0;
    var i = 0;
    while (i < format.length) {
      final c = format[i];
      if (c == r'\' && i + 1 < format.length) {
        final next = format[i + 1];
        const simple = {
          'n': '\n',
          't': '\t',
          'r': '\r',
          'a': '\x07',
          'b': '\b',
          'f': '\f',
          'v': '\v',
          'e': '\x1b',
          r'\': r'\',
        };
        if (simple.containsKey(next)) {
          out.write(simple[next]);
          i += 2;
          continue;
        }
        final hex = RegExp(r'x([0-9a-fA-F]{1,2})').matchAsPrefix(format, i + 1);
        if (hex != null) {
          out.writeCharCode(int.parse(hex[1]!, radix: 16));
          i = hex.end;
          continue;
        }
        final oct = RegExp(r'0?([0-7]{1,3})').matchAsPrefix(format, i + 1);
        if (oct != null) {
          out.writeCharCode(int.parse(oct[1]!, radix: 8));
          i = oct.end;
          continue;
        }
        out.write(c);
        i++;
      } else if (c == '%' && i + 1 < format.length) {
        final spec = format[i + 1];
        if (spec == '%') {
          out.write('%');
        } else if (spec == 's') {
          out.write(argIndex < args.length ? args[argIndex] : '');
          argIndex++;
        } else if (spec == 'd') {
          final arg = argIndex < args.length ? args[argIndex] : '0';
          out.write(int.tryParse(arg.trim()) ?? 0);
          argIndex++;
        } else {
          throw UnsupportedShellSyntaxError('printf %$spec is not supported');
        }
        i += 2;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  static String _emitPipeline(List<_Command> stages) {
    if (stages.length == 1) return _emit(stages.single, null);

    // Every stage but the last must produce output known at this point
    List<int>? bytes;
    for (final stage in stages.take(stages.length - 1)) {
      bytes = _staticOutput(stage, bytes);
    }
    return _emit(stages.last, bytes);
  }

  /// Output of a pipeline stage that needs no remote execution.
  static List<int> _staticOutput(_Command stage, List<int>? input) {
    final words = stage.words;
    switch (words.firstOrNull) {
      case 'printf' when words.length >= 2:
        return utf8.encode(printf(words[1], words.sublist(2)));
      case 'echo':
        return utf8.encode('${words.skip(1).join(' ')}\n');
      case 'base64' when words.length == 2 && words[1] == '-d':
        final text = latin1.decode(input ?? const []);
        return base64.decode(text.replaceAll(RegExp(r'\s'), ''));
    }
    throw UnsupportedShellSyntaxError(
      'pipeline stage "${words.join(' ')}" is not supported',
    );
  }

  static String _emit(_Command step, List<int>? stdin) {
    final words = step.words;
    if (words.isEmpty) {
      throw UnsupportedShellSyntaxError('empty command');
    }
    final args = words.sublist(1);
    switch (words.first) {
      case 'echo':
        return '__mpw ${literal(args.join(' '))}';
      case 'printf' when args.isNotEmpty:
        return '__mpo ${literal(printf(args.first, args.sublist(1)))}';
      case 'trap':
        return r'$global:LASTEXITCODE=0';
      case 'test'
          when args.length == 2 && const ['-e', '-f', '-x'].contains(args[0]):
        return '__mpt ${literal(args[1])}';
      case 'command' when args.length == 2 && args[0] == '-v':
        return '__mpc ${literal(args[1])}';
      case r'$SHELL'
          when args.length == 2 &&
              args[0].startsWith('-') &&
              args[0].contains('c'):
        return translate(args[1]);
    }
    final program = words.first;
    final argLine = args.map(windowsArg).join(' ');
    final input = stdin == null ? '' : " '${base64.encode(stdin)}'";
    return '__mpx ${literal(program)} ${literal(argLine)} ${step.stderrMode}$input';
  }

  static List<_Step> _parse(String command) {
    final steps = <_Step>[];
    var step = _Step(null);
    var cmd = _Command();
    step.stages.add(cmd);
    final word = StringBuffer();
    var inWord = false;
    var quoted = false;
    var i = 0;

    void endWord() {
      if (inWord) cmd.words.add(word.toString());
      word.clear();
      inWord = false;
      quoted = false;
    }

    void endStep(String separator) {
      endWord();
      steps.add(step);
      step = _Step(separator);
      cmd = _Command();
      step.stages.add(cmd);
    }

    while (i < command.length) {
      final c = command[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        endWord();
        i++;
      } else if (c == r'$' && i + 1 < command.length && command[i + 1] == "'") {
        i = _readAnsiC(command, i + 2, word);
        inWord = true;
        quoted = true;
      } else if (c == "'") {
        final close = command.indexOf("'", i + 1);
        if (close < 0) throw UnsupportedShellSyntaxError('unterminated quote');
        word.write(command.substring(i + 1, close));
        inWord = true;
        quoted = true;
        i = close + 1;
      } else if (c == '"') {
        inWord = true;
        quoted = true;
        i++;
        while (true) {
          if (i >= command.length) {
            throw UnsupportedShellSyntaxError('unterminated quote');
          }
          final d = command[i];
          if (d == '"') break;
          if (d == r'\' &&
              i + 1 < command.length &&
              r'\"$`'.contains(command[i + 1])) {
            word.write(command[i + 1]);
            i += 2;
            continue;
          }
          word.write(d);
          i++;
        }
        i++;
      } else if (c == r'\') {
        if (i + 1 < command.length) word.write(command[i + 1]);
        inWord = true;
        i += 2;
      } else if (c == ';') {
        endStep(';');
        i++;
      } else if (command.startsWith('&&', i)) {
        endStep('&&');
        i += 2;
      } else if (command.startsWith('||', i)) {
        endStep('||');
        i += 2;
      } else if (c == '|') {
        endWord();
        cmd = _Command();
        step.stages.add(cmd);
        i++;
      } else if (c == '&') {
        throw UnsupportedShellSyntaxError('background jobs are not supported');
      } else if (c == '>') {
        var fd = 1;
        if (inWord && !quoted && RegExp(r'^\d$').hasMatch(word.toString())) {
          fd = int.parse(word.toString());
          word.clear();
          inWord = false;
        } else {
          endWord();
        }
        i++;
        String target;
        if (i < command.length && command[i] == '&') {
          final m = RegExp(r'\d').matchAsPrefix(command, i + 1);
          if (m == null) throw UnsupportedShellSyntaxError('bad redirection');
          target = '&${m[0]}';
          i = m.end;
        } else {
          while (i < command.length && command[i] == ' ') {
            i++;
          }
          final m = RegExp(r'[^\s;&|]+').matchAsPrefix(command, i);
          if (m == null) throw UnsupportedShellSyntaxError('bad redirection');
          target = m[0]!;
          i = m.end;
        }
        cmd.redirect(fd, target);
      } else {
        word.write(c);
        inWord = true;
        i++;
      }
    }
    endWord();
    steps.add(step);
    // A trailing ';' leaves an empty last step
    if (steps.length > 1 &&
        steps.last.separator == ';' &&
        steps.last.stages.single.words.isEmpty) {
      steps.removeLast();
    }
    return steps;
  }

  /// Reads the body of `$'...'` starting at [start]; returns the index after
  /// the closing quote.
  static int _readAnsiC(String command, int start, StringBuffer word) {
    var i = start;
    while (i < command.length) {
      final c = command[i];
      if (c == "'") return i + 1;
      if (c == r'\' && i + 1 < command.length) {
        final next = command[i + 1];
        if (next == "'" || next == '"' || next == '?') {
          word.write(next);
          i += 2;
          continue;
        }
        // Same escapes as printf
        final m = RegExp(
          r'\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)',
        ).matchAsPrefix(command, i)!;
        word.write(printf(m[0]!, const []));
        i = m.end;
        continue;
      }
      word.write(c);
      i++;
    }
    throw UnsupportedShellSyntaxError('unterminated quote');
  }
}

/// One list element: a pipeline and the separator before it.
class _Step {
  final String? separator;
  final List<_Command> stages = [];

  _Step(this.separator);
}

class _Command {
  final List<String> words = [];

  /// 0 = pass stderr through, 1 = drop it, 2 = merge it into stdout
  int stderrMode = 0;

  void redirect(int fd, String target) {
    if (fd == 2 && target == '/dev/null') {
      stderrMode = 1;
    } else if (fd == 2 && target == '&1') {
      stderrMode = 2;
    } else {
      throw UnsupportedShellSyntaxError(
        'redirection $fd>$target is not supported',
      );
    }
  }
}
