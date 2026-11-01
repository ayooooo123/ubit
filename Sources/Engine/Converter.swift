import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import ImageIO

public enum MediaConverter {

    /// Converts any fetched thumbnail image (WebP, PNG, JPEG, AVIF) into compact baseline JPEG using macOS ImageIO.
    public static func normalizeThumbnailToJPEG(_ data: Data, maxDimension: Int = 1280) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Sets macOS Finder "Where from" metadata (`com.apple.metadata:kMDItemWhereFroms`) using binary plist `setxattr`.
    public static func setWhereFroms(fileURL: URL, sources: [String]) {
        let valid = sources.filter { !$0.isEmpty }
        guard !valid.isEmpty,
              let bplist = try? PropertyListSerialization.data(fromPropertyList: valid, format: .binary, options: 0) else {
            return
        }
        bplist.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = setxattr(fileURL.path, "com.apple.metadata:kMDItemWhereFroms", base, bplist.count, 0, 0)
        }
    }

    /// Applies original upload date (YYYY-MM-DD) as file modification date if enabled.
    public static func applyUploadDate(_ dateStr: String?, to fileURL: URL) {
        guard let dateStr, dateStr.count >= 10 else { return }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: String(dateStr.prefix(10))) {
            try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: fileURL.path)
        }
    }

    /// Adds finished file to macOS Music.app (audio) or TV.app (video).
    public static func addToAppleMediaLibrary(fileURL: URL, isAudio: Bool) {
        let appName = isAudio ? "Music" : "TV"
        let escaped = fileURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"\(appName)\" to add POSIX file \"\(escaped)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    public static func findSystemFFmpeg() -> String? {
        if let env = ProcessInfo.processInfo.environment["UBIT_FFMPEG"], FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let p = String(dir) + "/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Converts `inputURL` to `outputURL` in `targetFormat`.
    /// Uses 100% native macOS `AVFoundation` / `AudioToolbox` for `mov`, `m4a`, `wav`, `aiff`, `flac` (zero external FFmpeg!),
    /// and seamlessly uses `ffmpeg` when available for `mp3`, `opus`, `mkv`, `webm`.
    public static func convert(inputURL: URL, outputURL: URL, targetFormat: String) async throws {
        let fmt = targetFormat.lowercased()
        if inputURL.pathExtension.lowercased() == fmt {
            if inputURL != outputURL {
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }
                try FileManager.default.moveItem(at: inputURL, to: outputURL)
            }
            return
        }

        switch fmt {
        case "mov":
            try await exportAVAsset(inputURL: inputURL, outputURL: outputURL, fileType: .mov, preset: AVAssetExportPresetPassthrough)
            try? FileManager.default.removeItem(at: inputURL)
            return
        case "m4a":
            try await exportAVAsset(inputURL: inputURL, outputURL: outputURL, fileType: .m4a, preset: AVAssetExportPresetAppleM4A)
            try? FileManager.default.removeItem(at: inputURL)
            return
        case "wav", "aiff", "flac":
            do {
                try await decodeAndEncodeNativeAudio(inputURL: inputURL, outputURL: outputURL, format: fmt)
                try? FileManager.default.removeItem(at: inputURL)
                return
            } catch {
                // Fall through to ffmpeg if input container was VP9/Opus WebM unsupported by AVAssetReader
            }
        default:
            break
        }

        // FFmpeg conversion path for mp3, opus, mkv, webm (or non-Apple source codecs)
        guard let ffmpeg = findSystemFFmpeg() else {
            throw NSError(
                domain: "MediaConverter",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Converting to .\(fmt) requires ffmpeg on PATH (mp4, m4a, mov, wav, aiff, flac work natively with zero dependencies)."]
            )
        }
        try runFFmpeg(ffmpegPath: ffmpeg, inputURL: inputURL, outputURL: outputURL, format: fmt)
        try? FileManager.default.removeItem(at: inputURL)
    }

    private static func exportAVAsset(inputURL: URL, outputURL: URL, fileType: AVFileType, preset: String) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "MediaConverter", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unable to create AVAssetExportSession"])
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try await session.export(to: outputURL, as: fileType)
    }

    private static func decodeAndEncodeNativeAudio(inputURL: URL, outputURL: URL, format: String) async throws {
        let asset = AVURLAsset(url: inputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw NSError(domain: "MediaConverter", code: 12, userInfo: [NSLocalizedDescriptionKey: "No audio track found in source"])
        }

        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: (format == "aiff"),
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        reader.add(readerOutput)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writerSettings: [String: Any]
        let fileType: AVFileType
        switch format {
        case "aiff":
            fileType = .aiff
            writerSettings = pcmSettings
        case "flac":
            fileType = AVFileType("org.xiph.flac")
            writerSettings = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
            ]
        default: // wav
            fileType = .wav
            writerSettings = pcmSettings
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? NSError(domain: "MediaConverter", code: 13)
        }
        writer.startSession(atSourceTime: .zero)

        while let sampleBuf = readerOutput.copyNextSampleBuffer() {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            writerInput.append(sampleBuf)
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error { throw err }
    }

    public static func runFFmpegMux(videoURL: URL, audioURL: URL, outputURL: URL) throws {
        guard let ffmpeg = findSystemFFmpeg() else {
            throw NSError(domain: "MediaConverter", code: 14, userInfo: [NSLocalizedDescriptionKey: "Non-MP4 codec muxing (VP9/Opus) requires ffmpeg or --compatible mode."])
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-loglevel", "error", "-i", videoURL.path, "-i", audioURL.path, "-c", "copy", outputURL.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "MediaConverter", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ffmpeg mux failed: \(msg)"])
        }
    }

    private static func runFFmpeg(ffmpegPath: String, inputURL: URL, outputURL: URL, format: String) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        var args = ["-y", "-loglevel", "error", "-i", inputURL.path]
        switch format {
        case "mp3":
            args += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "opus":
            args += ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case "flac":
            args += ["-vn", "-c:a", "flac"]
        case "wav":
            args += ["-vn", "-c:a", "pcm_s16le"]
        case "mkv", "mov":
            args += ["-c", "copy"]
        case "webm":
            args += ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
        default:
            args += ["-c", "copy"]
        }
        args.append(outputURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "MediaConverter", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ffmpeg conversion failed: \(msg)"])
        }
    }
}
