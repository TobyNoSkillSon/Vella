import Foundation

// `vella`: shipped as Vella.app/Contents/Helpers/vella (product vella-cli: `vella` and `Vella` collide on a
// case-insensitive disk); install.sh links ~/.local/bin/vella to it.
let code = await VellaCLI().run(Array(CommandLine.arguments.dropFirst()))
exit(code)
