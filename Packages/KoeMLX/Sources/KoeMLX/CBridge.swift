#if arch(arm64)

import Foundation

// Singleton manager instance
private var manager = MLXAsrManager()

@_cdecl("koe_mlx_load_model")
public func koeMLXLoadModel(_ modelPath: UnsafePointer<CChar>?) -> Int32 {
    guard let modelPath = modelPath else { return -1 }
    let path = String(cString: modelPath)
    return manager.loadModel(path: path) ? 0 : -1
}

@_cdecl("koe_mlx_start_session")
public func koeMLXStartSession(
    _ language: UnsafePointer<CChar>?,
    _ delayPreset: UnsafePointer<CChar>?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> UInt64 {
    let lang = language.map { String(cString: $0) } ?? "auto"
    let preset = delayPreset.map { String(cString: $0) } ?? "realtime"
    return manager.startSession(
        language: lang,
        delayPreset: preset,
        callback: callback,
        context: ctx
    )
}

@_cdecl("koe_mlx_feed_audio")
public func koeMLXFeedAudio(_ samples: UnsafePointer<Float>?, _ count: UInt32, _ generation: UInt64) {
    guard let samples = samples else { return }
    manager.feedAudio(samples, count: Int(count), generation: generation)
}

@_cdecl("koe_mlx_stop")
public func koeMLXStop(_ generation: UInt64) {
    manager.stop(generation: generation)
}

@_cdecl("koe_mlx_cancel")
public func koeMLXCancel(_ generation: UInt64) {
    manager.cancel(generation: generation)
}

@_cdecl("koe_mlx_unload_model")
public func koeMLXUnloadModel() {
    manager.unloadModel()
}

#endif
