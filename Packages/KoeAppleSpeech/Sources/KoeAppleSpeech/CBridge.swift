import Foundation
import Speech

// Singleton manager instance
private var manager = AppleSpeechManager()

/// Start a streaming Apple Speech recognition session.
///
/// - Parameters:
///   - locale: Locale identifier (e.g. "zh_CN", "en_US")
///   - contextualStrings: Null-separated UTF-8 string blob for dictionary terms
///   - contextualStringsLen: Byte length of the contextualStrings blob
///   - callback: C callback for ASR events (event_type, text)
///   - ctx: Opaque pointer passed back to the callback
/// - Returns: Session generation (>0) on success, 0 on failure
@_cdecl("koe_apple_speech_start_session")
public func koeAppleSpeechStartSession(
    _ locale: UnsafePointer<CChar>?,
    _ contextualStrings: UnsafePointer<UInt8>?,
    _ contextualStringsLen: UInt32,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> UInt64 {
    guard let locale = locale else {
        callback(ctx, 3, "locale is required")
        callback(ctx, 5, nil)
        return 0
    }
    let localeStr = String(cString: locale)

    // Check speech recognition authorization before starting
    let authStatus = SFSpeechRecognizer.authorizationStatus()
    switch authStatus {
    case .authorized:
        break
    case .notDetermined:
        // First use — request authorization synchronously so the system dialog appears
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        SFSpeechRecognizer.requestAuthorization { status in
            granted = (status == .authorized)
            semaphore.signal()
        }
        semaphore.wait()
        if !granted {
            callback(ctx, 3, "Speech recognition permission was denied. Please grant in System Settings → Privacy & Security → Speech Recognition.")
            callback(ctx, 5, nil)
            return 0
        }
    default:
        callback(ctx, 3, "Speech recognition permission not granted. Please enable in System Settings → Privacy & Security → Speech Recognition.")
        callback(ctx, 5, nil)
        return 0
    }

    // Parse null-separated contextual strings
    var strings: [String] = []
    if let ptr = contextualStrings, contextualStringsLen > 0 {
        let data = Data(bytes: ptr, count: Int(contextualStringsLen))
        strings = data.split(separator: 0).compactMap { slice in
            String(bytes: slice, encoding: .utf8)
        }
    }

    return manager.startSession(
        locale: localeStr,
        contextualStrings: strings,
        callback: callback,
        context: ctx
    )
}

/// Feed raw PCM16 LE audio bytes into the current session.
@_cdecl("koe_apple_speech_feed_audio")
public func koeAppleSpeechFeedAudio(
    _ bytes: UnsafePointer<UInt8>?,
    _ count: UInt32,
    _ generation: UInt64
) {
    guard let bytes = bytes else { return }
    manager.feedAudio(bytes, count: Int(count), generation: generation)
}

/// Signal end of audio input, triggering final recognition.
@_cdecl("koe_apple_speech_stop")
public func koeAppleSpeechStop(_ generation: UInt64) {
    manager.stop(generation: generation)
}

/// Cancel the current session immediately.
@_cdecl("koe_apple_speech_cancel")
public func koeAppleSpeechCancel(_ generation: UInt64) {
    manager.cancel(generation: generation)
}

// MARK: - Asset Management (for Setup Wizard UI)

/// Check if Apple Speech APIs are available at runtime.
/// Returns 1 on macOS 26.0+, 0 otherwise.
@_cdecl("koe_apple_speech_is_available")
public func koeAppleSpeechIsAvailable() -> Int32 {
    if #available(macOS 26.0, *) {
        return 1
    }
    return 0
}

/// Return supported locales as a null-separated UTF-8 string blob.
/// Each entry is "identifier\0displayName" pairs separated by \0\0.
/// Format: "zh_CN\0Chinese (China mainland)\0\0en_US\0English (United States)\0\0..."
/// Ownership: the returned pointer was allocated with malloc().
/// The caller is responsible for freeing it (e.g. via free() or
/// NSData dataWithBytesNoCopy:freeWhenDone:YES).
/// Returns NULL if not available.
@_cdecl("koe_apple_speech_supported_locales")
public func koeAppleSpeechSupportedLocales(_ outLen: UnsafeMutablePointer<UInt32>) -> UnsafeMutablePointer<UInt8>? {
    guard #available(macOS 26.0, *) else {
        outLen.pointee = 0
        return nil
    }
    return _supportedLocalesImpl(outLen)
}

@available(macOS 26.0, *)
private func _supportedLocalesImpl(_ outLen: UnsafeMutablePointer<UInt32>) -> UnsafeMutablePointer<UInt8>? {
    var locales: [Locale] = []
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        locales = await SpeechTranscriber.supportedLocales
        semaphore.signal()
    }
    semaphore.wait()

    guard !locales.isEmpty else {
        outLen.pointee = 0
        return nil
    }

    // Sort by localized display name using localized compare (respects pinyin for CJK)
    let sorted = locales.sorted { a, b in
        let nameA = Locale.current.localizedString(forIdentifier: a.identifier) ?? a.identifier
        let nameB = Locale.current.localizedString(forIdentifier: b.identifier) ?? b.identifier
        return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
    }

    // Build blob: "id\0displayName\0\0id\0displayName\0\0..."
    var blob = Data()
    for locale in sorted {
        let identifier = locale.identifier
        let displayName = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        blob.append(contentsOf: identifier.utf8)
        blob.append(0)
        blob.append(contentsOf: displayName.utf8)
        blob.append(0)
        blob.append(0) // double-null separator between entries
    }

    let ptr = malloc(blob.count)!.assumingMemoryBound(to: UInt8.self)
    blob.copyBytes(to: UnsafeMutableBufferPointer(start: ptr, count: blob.count))
    outLen.pointee = UInt32(blob.count)
    return ptr
}

/// Check asset installation status for a given locale.
/// Returns: 0=unsupported, 1=supported (downloadable), 2=downloading, 3=installed
/// Blocks the calling thread until the async check completes.
@_cdecl("koe_apple_speech_asset_status")
public func koeAppleSpeechAssetStatus(_ locale: UnsafePointer<CChar>?) -> Int32 {
    guard #available(macOS 26.0, *) else { return 0 }
    return _assetStatusImpl(locale)
}

@available(macOS 26.0, *)
private func _assetStatusImpl(_ locale: UnsafePointer<CChar>?) -> Int32 {
    guard let locale = locale else { return 0 }
    let localeStr = String(cString: locale)
    let loc = Locale(identifier: localeStr)
    let transcriber = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)

    var result: Int32 = 0
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .unsupported: result = 0
        case .supported:   result = 1
        case .downloading: result = 2
        case .installed:   result = 3
        @unknown default:  result = 0
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

/// Install speech recognition assets for a given locale.
/// Calls `callback(ctx, event_type, text)` with:
///   event_type 0 = progress (text = "Downloading… XX%")
///   event_type 1 = completed successfully
///   event_type 2 = error (text = error message)
@_cdecl("koe_apple_speech_install_asset")
public func koeAppleSpeechInstallAsset(
    _ locale: UnsafePointer<CChar>?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard #available(macOS 26.0, *) else {
        callback(ctx, 2, "Apple Speech requires macOS 26.0 or later")
        return
    }
    _installAssetImpl(locale, callback, ctx)
}

/// Release (unpin) speech recognition assets for a given locale.
/// The system may reclaim the storage when space is needed.
/// Returns: 1 if released successfully, 0 otherwise.
/// Blocks the calling thread until the async operation completes.
@_cdecl("koe_apple_speech_release_asset")
public func koeAppleSpeechReleaseAsset(_ locale: UnsafePointer<CChar>?) -> Int32 {
    guard #available(macOS 26.0, *) else { return 0 }
    return _releaseAssetImpl(locale)
}

@available(macOS 26.0, *)
private func _releaseAssetImpl(_ locale: UnsafePointer<CChar>?) -> Int32 {
    guard let locale = locale else { return 0 }
    let localeStr = String(cString: locale)
    let loc = Locale(identifier: localeStr)

    var result: Int32 = 0
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let released = await AssetInventory.release(reservedLocale: loc)
        result = released ? 1 : 0
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

@available(macOS 26.0, *)
private func _installAssetImpl(
    _ locale: UnsafePointer<CChar>?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard let locale = locale else {
        callback(ctx, 2, "locale is required")
        return
    }
    let localeStr = String(cString: locale)
    let loc = Locale(identifier: localeStr)
    let transcriber = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)

    Task {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                callback(ctx, 1, nil) // Already installed or nothing to do
                return
            }

            // Observe progress
            let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                let pct = Int(progress.fractionCompleted * 100)
                let text = "Downloading… \(pct)%"
                text.withCString { cstr in
                    callback(ctx, 0, cstr)
                }
            }

            try await request.downloadAndInstall()
            observation.invalidate()
            callback(ctx, 1, nil) // Completed
        } catch {
            error.localizedDescription.withCString { cstr in
                callback(ctx, 2, cstr)
            }
        }
    }
}
