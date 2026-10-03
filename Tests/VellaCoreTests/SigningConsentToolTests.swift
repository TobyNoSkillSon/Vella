import Foundation
import XCTest
import VellaTestSupport

/// Real PTY/pipe descriptors enter the debug tool's exact production consent dispatcher, never an installer.
final class SigningConsentToolTests: XCTestCase {
    func testFlagTTYRedirectedStderrAndPipedStdinConsentMatrix() throws {
        let script = #"""
            import os, pty, subprocess, sys, tempfile
            tool = sys.argv[1]
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
                                result = subprocess.run(args, stdout=subprocess.PIPE,
                                    stderr=err if redirected else subprocess.PIPE, timeout=8, **input_args)
                                if redirected:
                                    err.seek(0); error = err.read()
                                else: error = result.stderr
                            if master is not None: os.close(master); os.close(slave)
                            consent = flag and (not terminal or answer == b'y\n')
                            assert (result.returncode == 0) == consent, (terminal, redirected, flag, answer, result.returncode, error)
                            assert (b'consented' in result.stdout) == consent
                            if flag and terminal: assert b'[y/N]' in error
                            if flag and not terminal: assert b'explicitly authorized by --migrate-signing (noninteractive stdin)' in error
                            if not flag: assert b'consented' not in result.stdout
                            review = os.environ.get('VELLA_RENDER_REVIEW_DIR')
                            if review and redirected and flag and (not terminal or answer == b'n\n'):
                                os.makedirs(review, exist_ok=True)
                                name = 'installer-signing-terminal-declined' if terminal else 'installer-signing-noninteractive'
                                with open(os.path.join(review, name + '.txt'), 'wb') as f: f.write(error + result.stdout)
            print('consent matrix passed: terminal yes/no/EOF, redirected/captured stderr, piped stdin, flag present/absent')
            """#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, Repository.root.appendingPathComponent(".build/debug/VellaInstallTool").path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("consent matrix passed"), text)
    }
}
