import 'dart:convert';

import 'package:flutter_muxpod/services/ssh/remote_shell.dart';
import 'package:flutter_muxpod/services/ssh/shell_marker_protocol.dart';
import 'package:flutter_muxpod/services/tmux/commands/content_commands.dart';
import 'package:flutter_muxpod/services/tmux/commands/input_commands.dart';
import 'package:flutter_muxpod/services/tmux/commands/lifecycle_commands.dart';
import 'package:flutter_muxpod/services/tmux/commands/session_commands.dart';
import 'package:flutter_muxpod/services/tmux/tmux_executable_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteShell.fromProbe', () {
    test('bash prints the literal %OS%', () {
      expect(RemoteShell.fromProbe('%OS%\n'), RemoteShell.posix);
    });

    test('PowerShell prints %OS% and its major version', () {
      expect(RemoteShell.fromProbe('%OS%\r\n5\r\n'), RemoteShell.powershell);
      expect(RemoteShell.fromProbe('%OS%\n7\n'), RemoteShell.powershell);
    });

    test('cmd.exe expands %OS%', () {
      expect(
        RemoteShell.fromProbe(
          'Windows_NT;\$PSVersionTable.PSVersion.Major\r\n',
        ),
        RemoteShell.cmd,
      );
    });

    test('empty output falls back to POSIX', () {
      expect(RemoteShell.fromProbe(''), RemoteShell.posix);
    });
  });

  group('PowerShellCommand.windowsArg', () {
    test('plain words stay as they are', () {
      expect(PowerShellCommand.windowsArg('%1'), '%1');
      expect(
        PowerShellCommand.windowsArg('#{session_name}|||#{session_id}'),
        '#{session_name}|||#{session_id}',
      );
    });

    test('whitespace and empty strings are quoted', () {
      expect(PowerShellCommand.windowsArg('a b'), '"a b"');
      expect(PowerShellCommand.windowsArg(''), '""');
    });

    test('quotes and backslashes follow CommandLineToArgvW', () {
      expect(PowerShellCommand.windowsArg('say "hi"'), r'"say \"hi\""');
      expect(PowerShellCommand.windowsArg(r'C:\my dir\'), r'"C:\my dir\\"');
      expect(PowerShellCommand.windowsArg(r'a\"b'), r'"a\\\"b"');
      expect(PowerShellCommand.windowsArg(r'a\b c'), r'"a\b c"');
    });
  });

  group('PowerShellCommand.literal', () {
    test('single quotes are doubled, nothing expands', () {
      expect(PowerShellCommand.literal("it's"), "'it''s'");
      expect(PowerShellCommand.literal(r'$HOME `x`'), r"'$HOME `x`'");
    });

    test('control characters become [char] codes', () {
      expect(PowerShellCommand.literal('\x1b[I'), "(''+[char]27+'[I')");
      expect(PowerShellCommand.literal('a\nb'), "(''+'a'+[char]10+'b')");
    });

    test('empty string', () {
      expect(PowerShellCommand.literal(''), "''");
    });
  });

  group('PowerShellCommand.printf', () {
    test('escapes and conversions', () {
      expect(PowerShellCommand.printf(r'\x01#a\n', []), '\x01#a\n');
      expect(PowerShellCommand.printf('%s-%d%%', ['x', '7']), 'x-7%');
      expect(PowerShellCommand.printf(r'\033[0m\\', []), '\x1b[0m\\');
    });
  });

  group('PowerShellCommand.translate', () {
    test('tmux runs through __mpx with a CommandLineToArgvW line', () {
      expect(
        PowerShellCommand.translate(
          TmuxContentCommands.capture('%1', startLine: -1000),
        ),
        "__mpx 'tmux' 'capture-pane -t %1 -p -e -S -1000' 0",
      );
    });

    test('resolved path and -u from TmuxExecutableResolver', () {
      final command =
          "${TmuxExecutableResolver.shQuote(r'C:\bin\tmux.exe')} -u list-sessions";
      expect(
        PowerShellCommand.translate(command),
        r"__mpx 'C:\bin\tmux.exe' '-u list-sessions' 0",
      );
    });

    test('format strings lose the POSIX quotes', () {
      expect(
        PowerShellCommand.translate(TmuxContentCommands.cursorPosition('%1')),
        "__mpx 'tmux' 'display-message -p -t %1 "
        "#{cursor_x},#{cursor_y},#{pane_width},#{pane_height}' 0",
      );
    });

    test('literal send-keys text keeps quotes and spaces', () {
      expect(
        PowerShellCommand.translate(
          TmuxInputCommands.sendKeys(
            '%1',
            r'''git commit -m "it's $x"''',
            literal: true,
          ),
        ),
        r'''__mpx 'tmux' 'send-keys -t %1 -l -- "git commit -m \"it''s $x\""' 0''',
      );
    });

    test(r"$'...' escape sequences survive", () {
      expect(
        PowerShellCommand.translate(
          TmuxInputCommands.sendKeys('%1', '\x1b[I', literal: true),
        ),
        "__mpx 'tmux' (''+'send-keys -t %1 -l -- '+[char]27+'[I') 0",
      );
    });

    test('session names with spaces', () {
      expect(
        PowerShellCommand.translate(
          TmuxSessionCommands.create(name: 'my work'),
        ),
        "__mpx 'tmux' 'new-session -d -s \"my work\"' 0",
      );
    });

    test('&&, || and 2>/dev/null', () {
      expect(
        PowerShellCommand.translate(TmuxSessionCommands.has('main')),
        "__mpx 'tmux' 'has-session -t main' 1"
        r";if($LASTEXITCODE -eq 0){__mpw '1'}"
        r";if($LASTEXITCODE -ne 0){__mpw '0'}",
      );
    });

    test('2>&1 merges stderr', () {
      expect(
        PowerShellCommand.translate(TmuxSessionCommands.serverInfo()),
        "__mpx 'tmux' 'server-info' 2",
      );
    });

    test(r'\; is a literal tmux command separator', () {
      expect(
        PowerShellCommand.translate(
          r'tmux resize-window -t @1 -A \; set -uw -t @1 window-size',
        ),
        "__mpx 'tmux' 'resize-window -t @1 -A ; set -uw -t @1 window-size' 0",
      );
    });

    test('paste pipeline feeds the decoded text to stdin', () {
      final command = TmuxInputCommands.paste('%1', 'héllo "x"');
      final script = PowerShellCommand.translate(command);
      final stdin = RegExp(
        r"__mpx 'tmux' '-?[^']*load-buffer[^']*' 0 '([^']+)'",
      ).firstMatch(script)![1]!;
      expect(utf8.decode(base64.decode(stdin)), 'héllo "x"');
      expect(script, contains(r';if($LASTEXITCODE -eq 0){__mpx '));
    });

    test('printf and echo become raw writes', () {
      expect(PowerShellCommand.translate('echo ping'), "__mpw 'ping'");
      expect(
        PowerShellCommand.translate(r"printf '\x01###POLL_ab###\x01\n'"),
        "__mpo (''+[char]1+'###POLL_ab###'+[char]1+[char]10)",
      );
    });

    test('trap is a no-op', () {
      expect(
        PowerShellCommand.translate(
          TmuxLifecycleCommands.windowRestoreTrap(['@1'], tmuxBin: 'tmux'),
        ),
        r'$global:LASTEXITCODE=0',
      );
      expect(
        PowerShellCommand.translate(
          TmuxLifecycleCommands.clearWindowRestoreTrap(),
        ),
        r'$global:LASTEXITCODE=0',
      );
    });

    test('tmux detection commands', () {
      expect(
        PowerShellCommand.translate(r"$SHELL -lc 'command -v tmux'"),
        "__mpc 'tmux'",
      );
      expect(
        PowerShellCommand.translate(
          'test -x ${TmuxExecutableResolver.shQuote(r'C:\x\tmux.exe')}',
        ),
        r"__mpt 'C:\x\tmux.exe'",
      );
    });

    test('unsupported syntax is rejected', () {
      expect(
        () => PowerShellCommand.translate('tmux ls | head'),
        throwsA(isA<UnsupportedShellSyntaxError>()),
      );
      expect(
        () => PowerShellCommand.translate('sleep 1 &'),
        throwsA(isA<UnsupportedShellSyntaxError>()),
      );
      expect(
        () => PowerShellCommand.translate('tmux ls > out.txt'),
        throwsA(isA<UnsupportedShellSyntaxError>()),
      );
    });
  });

  group('ShellMarkerProtocol.buildPowerShellCommand', () {
    test('frames the script with the same marker bytes as bash', () {
      final protocol = ShellMarkerProtocol();
      final framed = protocol.buildPowerShellCommand(
        "__mpw 'x'",
        captureExitCode: true,
      );
      expect(framed, endsWith('\n'));
      expect('\n'.allMatches(framed).length, 1);
      expect(framed, contains("__mpw 'x';\$__rc=\$LASTEXITCODE;"));
      expect(
        framed,
        startsWith(
          "__mpw (''+[char]1+'###START_${protocol.markerId}###'+[char]1);",
        ),
      );
    });
  });
}
