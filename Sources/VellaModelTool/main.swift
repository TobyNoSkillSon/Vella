import Foundation

// Retired: Vella downloads models itself. The executable still ships (as a stub) because the in-app updater of Vella
// 1.0.x refuses a release bundle without Contents/MacOS/VellaModelTool; it goes once those updaters are gone.
FileHandle.standardError.write(Data("VellaModelTool is retired; Vella downloads models itself.\n".utf8))
exit(2)
