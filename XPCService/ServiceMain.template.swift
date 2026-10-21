import Foundation
import SekitiriInferenceXPCService

// Integration template: replace `SekitiriInferenceHandler()` with the adapter
// that owns LocalSummaryRuntime, ParakeetEngine, and Sortformer after those
// implementations are moved into the shared SekitiriInferenceCore target.
//
// let service = InferenceWorkerService(
//     handler: SekitiriInferenceHandler(),
//     serviceVersion: "1.0"
// )
// let delegate = InferenceWorkerListener(exportedObject: service)
// withExtendedLifetime(delegate) {
//     NSXPCListener.service().resume()
// }
