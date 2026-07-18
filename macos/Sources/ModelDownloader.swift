// The manifest download engine, UI-agnostic on purpose: onboarding and the
// Settings model switcher drive different widgets with the same downloader,
// and the test harness compiles this file standalone (keep app state out).

import Cocoa

/// UTF-8 C string to Swift String; "" for NULL. The C API hands out static
/// manifest strings, so no ownership transfer happens here.
func booCString(_ p: UnsafePointer<CChar>?) -> String {
    p.map { String(cString: $0) } ?? ""
}

/// Streams one manifest model with progress, verifies its pinned SHA-256, moves
/// it into ~/.boo/models, and reports the final path. UI-agnostic: progress,
/// success, and failure surface through closures (called on the main queue),
/// so onboarding and the Settings model switcher drive different widgets with
/// the same downloader.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void  // 0..100
    private let onDone: (String) -> Void  // verified path in ~/.boo/models
    private let onFail: (String) -> Void
    private var session: URLSession?
    private var model: BooModelInfo?
    // A download reaches exactly one terminal outcome; guards a second fail (the
    // size-cap cancel below surfaces again through didCompleteWithError).
    private var finished = false

    init(
        onProgress: @escaping (Double) -> Void, onDone: @escaping (String) -> Void,
        onFail: @escaping (String) -> Void
    ) {
        self.onProgress = onProgress
        self.onDone = onDone
        self.onFail = onFail
    }

    func start(model: BooModelInfo) {
        guard let url = URL(string: booCString(model.url)) else {
            // Callers freeze their UI before calling start; a silent return
            // would leave a permanently dead dialog.
            onFail("The model's download URL is invalid.")
            return
        }
        self.model = model
        let cfg = URLSessionConfiguration.default
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        session?.downloadTask(with: url).resume()
    }

    /// A delegate-owning URLSession retains its delegate until invalidated;
    /// without this every downloader (and everything its closures capture)
    /// leaks for the life of the process.
    private func retire() {
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func urlSession(
        _: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
        guard let model = model else { return }
        // Cap the transfer at the pinned size so a misbehaving server can't fill
        // the disk before the checksum ever runs; the Linux and Windows
        // downloaders enforce the same bound. A correct file reaches exactly
        // model.size, so only an overrun trips this.
        if UInt64(totalBytesWritten) > model.size {
            downloadTask.cancel()
            fail("The download is larger than the model. Try again.")
            return
        }
        if model.size > 0 { onProgress(Double(totalBytesWritten) / Double(model.size) * 100) }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let model = model else { return }
        // URLSession deletes `location` the moment this returns, so claim the
        // file synchronously with a cheap rename; the actual hashing of
        // hundreds of megabytes happens off the main queue, or the app
        // beachballs at 100% while a large model verifies.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("boo-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            fail("Could not read the download.")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.verifyAndInstall(model: model, staging: staging)
        }
    }

    /// Off-main: hash against the pinned digest, then move into place.
    /// Outcomes hop back to the main queue, where the UI closures live.
    private func verifyAndInstall(model: BooModelInfo, staging: URL) {
        defer { try? FileManager.default.removeItem(at: staging) }
        // The pinned-digest check lives in the tested core (boo_model_verify_sha256),
        // one streaming implementation for all three frontends.
        switch boo_model_verify_sha256(staging.path, model.sha256) {
        case Int32(BOO_MODEL_SHA_OK):
            break
        case Int32(BOO_MODEL_SHA_MISMATCH):
            DispatchQueue.main.async { self.fail("Downloaded file failed its checksum. Try again.") }
            return
        default:  // UNREADABLE
            DispatchQueue.main.async { self.fail("Could not read the download.") }
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".boo/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(booCString(model.filename))
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: staging, to: dest)
        } catch {
            DispatchQueue.main.async { self.fail("Could not save the model file.") }
            return
        }
        boo_log(Int32(BOO_LOG_INFO), "model downloaded and verified")
        DispatchQueue.main.async {
            self.retire()
            self.onDone(dest.path)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { fail("Download failed: \(error.localizedDescription)") }
    }

    private func fail(_ why: String) {
        if finished { return }
        finished = true
        boo_log(Int32(BOO_LOG_ERROR), "model download failed")
        retire()
        onFail(why)
    }
}
