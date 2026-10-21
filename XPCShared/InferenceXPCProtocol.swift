import Foundation

/// The deliberately small Objective-C surface accepted by NSXPCConnection.
/// Codable values are wrapped in Data to keep the interface stable as the
/// inference pipeline evolves.
@objc public protocol SekitiriInferenceXPCProtocol {
    func perform(_ requestData: Data, withReply reply: @escaping (Data?, Data?) -> Void)
    func status(_ requestID: String, withReply reply: @escaping (Data?, Data?) -> Void)
    func cancel(_ requestID: String)
    func healthCheck(withReply reply: @escaping (Data?, Data?) -> Void)
    func unloadModels(withReply reply: @escaping (Data?) -> Void)
}
