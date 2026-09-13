"""Check the selected Apple tools before building or changing an installed app."""
from pathlib import Path
import subprocess
import sys


def check():
    root = Path(__file__).resolve().parents[1]
    fixture = root / 'Tests/StateCompatibilityFixture.swift'
    commands = [(['xcrun', 'swift', 'package', '--version'], 30),
                (['xcrun', 'swiftc', '-typecheck', '-target', 'arm64-apple-macosx14.0', str(fixture)], 120)]
    print('Checking Apple developer tools and SwiftUI compatibility…', flush=True)
    for command, deadline in commands:
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=deadline)
        except (OSError, subprocess.SubprocessError) as error:
            detail = (getattr(error, 'stderr', '') or str(error))
            if isinstance(detail, bytes):
                detail = detail.decode(errors='replace')
            print(detail[-3000:], file=sys.stderr)
            sys.exit('Vella: The selected Apple developer tools cannot build this app. '
                     'Install or repair a matching Command Line Tools package with '
                     'xcode-select --install (or select a complete Xcode installation), then retry. '
                     'Avoid installing an older tools package over a newer one. '
                     'Your existing Vella app has not been replaced.')


if __name__ == '__main__':
    check()
