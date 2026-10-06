import Foundation
import XCTest
import VellaTestSupport

/// Real PTY/pipe descriptors enter the debug tool's exact production consent dispatcher, never an installer.
final class SigningConsentToolTests: XCTestCase {
    func testFlagTTYRedirectedStderrAndPipedStdinConsentMatrix() throws {
        let script = #"""
            import os, pathlib, pty, subprocess, sys, tempfile
            tool, root = sys.argv[1:]
            routes = [
                ('scripts/install.sh', 'scripts/install.sh 2.0.0 --migrate-signing'),
                ('scripts/install-public.sh', 'curl -fsSL https://raw.githubusercontent.com/TobyNoSkillSon/Vella/main/scripts/install-public.sh | env VELLA_DESTINATION_APP=/fixture/Vella.app VELLA_VERSION=2.0.0 VELLA_SUPPORT_DIR=/fixture/support VELLA_BIN_DIR=/fixture/bin bash -s -- --migrate-signing'),
                ('scripts/install-release.sh', 'scripts/install-release.sh 2.0.0 --migrate-signing'),
                ('scripts/install-prepared.sh', "scripts/install-prepared.sh /fixture/Vella.app --migrate-signing"),
            ]
            for route, expected in routes:
                # Exercise each actual entry point's exported invocation without downloading or installing.
                lines = pathlib.Path(root, route).read_text().splitlines()
                export = next(line.strip() for line in lines if 'export VELLA_INSTALL_RETRY_COMMAND=' in line)
                env = dict(os.environ); env.pop('VELLA_INSTALL_RETRY_COMMAND', None); env.pop('VELLA_RELEASE_BASE_URL', None); env.pop('VELLA_VERSION', None)
                retry = subprocess.check_output(['/bin/bash', '-c', 'VERSION=2.0.0; RETRY_VERSION=2.0.0; APP=/fixture/Vella.app; DEST=/fixture/Vella.app; SUPPORT=/fixture/support; VELLA_BIN_DIR=/fixture/bin; '
                    + export + '; printf %s "$VELLA_INSTALL_RETRY_COMMAND"'], env=env, timeout=5).decode()
                assert retry == expected, (route, retry)
                env['VELLA_INSTALL_RETRY_COMMAND'] = retry
                for terminal in (True, False):
                    for redirected in (True, False):
                        for flag in (True, False):
                            for answer in (b'y\n', b'n\n', b'\x04') if terminal else (b'y\n',):
                                master = slave = None
                                if terminal:
                                    master, slave = pty.openpty()
                                    os.write(master, answer)
                                with tempfile.TemporaryFile() as err:
                                    args = [tool, '--signing-consent-fixture'] + (['--migrate-signing'] if flag else [])
                                    input_args = {'stdin': slave} if terminal else {'input': answer}
                                    result = subprocess.run(args, stdout=subprocess.PIPE, env=env,
                                        stderr=err if redirected else subprocess.PIPE, timeout=8, **input_args)
                                    if redirected:
                                        err.seek(0); error = err.read()
                                    else: error = result.stderr
                                if master is not None: os.close(master); os.close(slave)
                                consent = flag and (not terminal or answer == b'y\n')
                                assert (result.returncode == 0) == consent, (route, terminal, redirected, flag, answer, error)
                                assert result.stdout == b'', result.stdout
                                assert b'consented' not in error
                                if flag and terminal: assert b'[y/N] \n' in error, error
                                if flag and not terminal:
                                    assert error.endswith(b'Signing migration authorized by --migrate-signing.\n'), error
                                if not consent:
                                    assert expected.encode() in error, (route, error)
                                if flag and terminal and not consent:
                                    assert error.endswith(b'Signing migration declined; existing app and data unchanged. Re-run: '
                                        + expected.encode() + b'\n'), error
                                review = os.environ.get('VELLA_RENDER_EXACT_TEXT_DIR')
                                if review and redirected and flag and (not terminal or answer == b'n\n'):
                                    os.makedirs(review, exist_ok=True)
                                    name = None
                                    if route == 'scripts/install.sh':
                                        name = 'installer-signing-terminal-declined' if terminal else 'installer-signing-noninteractive'
                                    elif route == 'scripts/install-public.sh' and terminal: name = 'installer-signing-public-declined'
                                    if name:
                                        with open(os.path.join(review, name + '.txt'), 'wb') as f:
                                            f.write(expected.encode() + b'\n\n' + error + result.stdout)
            print('consent matrix passed: four actual invocations, terminal yes/no/EOF, redirected/captured stderr, piped stdin, flag present/absent')
            """#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, Repository.root.appendingPathComponent(".build/debug/VellaInstallTool").path, Repository.root.path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("consent matrix passed"), text)
    }
    /// Execute the printed retry with fake route endpoints, not merely inspect its text.
    /// Quotes/metacharacters must round-trip and cannot redirect a custom install to ~/Applications.
    func testPrintedRetriesPreserveCustomDestinationVersionAndSupport() throws {
        try Integration.require()
        let script = #"""
            import json, os, pathlib, subprocess, sys, tempfile
            root = pathlib.Path(sys.argv[1])
            with tempfile.TemporaryDirectory(prefix='vella-retry-') as temp:
                home = pathlib.Path(temp)
                dest = str(home / "quote's space $literal; Vella.app")
                support = str(home / "support's $literal")
                binpath = str(home / 'bin')
                env = dict(os.environ, HOME=temp, VELLA_DESTINATION_APP=dest, VELLA_SUPPORT_DIR=support,
                    VELLA_BIN_DIR=binpath, VELLA_VERSION='9.8.7', VELLA_RELEASE_BASE_URL='file:///custom release')
                env.pop('VELLA_INSTALL_RETRY_COMMAND', None)
                capture = '''#!/bin/bash
            /usr/bin/python3 -c 'import json,os,sys; print(json.dumps([os.environ.get(k) for k in ["VELLA_DESTINATION_APP","VELLA_SUPPORT_DIR","VELLA_BIN_DIR","VELLA_VERSION","VELLA_RELEASE_BASE_URL"]]+[sys.argv[1:]]))' "$@"
            '''
                scripts = home / 'scripts'; scripts.mkdir()
                for name in ['install.sh', 'install-release.sh', 'install-prepared.sh']:
                    path = scripts / name; path.write_text(capture); path.chmod(0o755)
                for route in ['scripts/install-public.sh', 'scripts/install.sh', 'scripts/install-release.sh', 'scripts/install-prepared.sh']:
                    lines = (root / route).read_text().splitlines()
                    export = next(line.strip() for line in lines if 'export VELLA_INSTALL_RETRY_COMMAND=' in line)
                    if route != 'scripts/install-public.sh':
                        prepared = (root / 'scripts/install-prepared.sh').read_text().splitlines()
                        # install.sh/release.sh supply the route; prepared.sh adds selected destination/support.
                        context = next(line for line in prepared if line.startswith('VELLA_INSTALL_RETRY_COMMAND="env '))
                        export += '\n' + context
                    setup = 'VERSION=9.8.7; RETRY_VERSION=9.8.7; APP=/fixture/Vella.app; DEST="$VELLA_DESTINATION_APP"; SUPPORT="$VELLA_SUPPORT_DIR"; '
                    retry = subprocess.check_output(['/bin/bash', '-c', setup + export + '\nprintf %s "$VELLA_INSTALL_RETRY_COMMAND"'], env=env, timeout=5).decode()
                    # A real curl pipe would authorize via nonterminal stdin; replace only retrieval with the fixture.
                    command = "curl() { cat <<'CAPTURE'\n" + capture + "CAPTURE\n}; " + retry
                    clean = dict(env)
                    for key in ['VELLA_DESTINATION_APP', 'VELLA_SUPPORT_DIR', 'VELLA_BIN_DIR', 'VELLA_VERSION', 'VELLA_RELEASE_BASE_URL']:
                        clean.pop(key, None)
                    result = json.loads(subprocess.check_output(['/bin/bash', '-c', command], cwd=temp, env=clean, timeout=5))
                    assert result[:3] == [dest, support, binpath], (route, retry, result)
                    assert result[4] == 'file:///custom release', (route, result)
                    assert '--migrate-signing' in result[5], (route, result)
                    if route == 'scripts/install-public.sh': assert result[3] == '9.8.7', result
                    elif route != 'scripts/install-prepared.sh': assert '9.8.7' in result[5], result
                print('retry context passed: every route, quoted custom destination/support, version and release base')
            """#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, Repository.root.path]
        process.standardOutput = output; process.standardError = output
        try process.run(); let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("retry context passed"), text)
    }

}
