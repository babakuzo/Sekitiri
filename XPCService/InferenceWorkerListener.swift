import Foundation
import SekitiriInferenceXPCShared

/// Own this delegate for the lifetime of the service process, then call
/// `NSXPCListener.service().resume()` from the service executable's main file.
public final class InferenceWorkerListener: NSObject, NSXPCListenerDelegate {
    private let exportedObject: InferenceWorkerService

    public init(exportedObject: InferenceWorkerService) {
        self.exportedObject = exportedObject
        super.init()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SekitiriInferenceXPCProtocol.self)
        connection.exportedObject = exportedObject
        connection.invalidationHandler = {}
        connection.interruptionHandler = {}
        connection.resume()
        return true
    }
}
