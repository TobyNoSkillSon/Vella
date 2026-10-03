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
                ('scripts/install.sh', 'scripts/install.sh --migrate-signing'),
                ('docs/install.sh', 'curl -fsSL https://tobynoskillson.github.io/Vella/install.sh | bash -s -- --migrate-signing'),
                ('scripts/install-release.sh', 'scripts/install-release.sh 2.0.0 --migrate-signing'),
                ('scripts/install-prepared.sh', "scripts/install-prepared.sh /fixture/Vella.app --migrate-signing"),
            ]
            for route, expected in routes:
                # Exercise each actual entry point's exported invocation without downloading or installing.
                lines = pathlib.Path(root, route).read_text().splitlines()
                export = next(line.strip() for line in lines if 'export VELLA_INSTALL_RETRY_COMMAND=' in line)
                env = dict(os.environ); env.pop('VELLA_INSTALL_RETRY_COMMAND', None)
                retry = subprocess.check_output(['/bin/bash', '-c', 'VERSION=2.0.0; APP=/fixture/Vella.app; '
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
                                    elif route == 'docs/install.sh' and terminal: name = 'installer-signing-public-declined'
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
}
