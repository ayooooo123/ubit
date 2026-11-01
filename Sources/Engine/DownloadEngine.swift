import Foundation

public struct DownloadRequestOptions: Sendable {
    public var outputDir: String?
    public var audioOnly: Bool = false
    public var targetFormat: String?        // mp4, m4a, mov, wav, flac, mkv, webm, mp3, opus
    public var maxQuality: String = "best"  // best, 2160, 1440, 1080, 720, 480, 360
    public var formatSelector: String?      // e.g. "137+140" or "299+140" or "18"
    public var preferCompatible: Bool = true
    public var downloadSubtitles: Bool = false
    public var subtitleLangs: String = "en"
    public var externalSubtitles: Bool = false
    public var section: SectionRange?
    public var sponsorMode: String = "keep" // "keep", "mark", "remove"
    public var sponsorCategories: String = "default"
    public var customTitle: String?
    public var filenameTemplate: String?
    public var rateLimit: String?
    public var connections: Int = 8
    public var cookieSource: String = "builtin"
    public var proxy: String?
    public var referer: String?
    public var userAgent: String?
    public var extraHeaders: [String: String] = [:]
    public var playlistTitle: String?

    public init() {}

    public static func from(settings: Settings) -> DownloadRequestOptions {
        var o = DownloadRequestOptions()
        o.outputDir = settings.folder
        o.audioOnly = (settings.mode == "audio")
        o.maxQuality = settings.quality
        o.preferCompatible = settings.compatible
        o.downloadSubtitles = settings.subtitles
        o.subtitleLangs = settings.subtitleLangs
        o.externalSubtitles = !settings.embedSubtitles
        o.sponsorMode = settings.sponsors
        o.filenameTemplate = settings.template
        o.rateLimit = settings.rateLimit.isEmpty ? nil : settings.rateLimit
        o.connections = settings.connections
        o.cookieSource = settings.cookies
        o.proxy = settings.proxy.isEmpty ? nil : settings.proxy
        return o
    }
}

public enum DownloadEventPayload: Sendable {
    case start(url: String)
    case info(title: String, site: String, quality: String, ext: String, path: String, isLive: Bool, thumbnail: String?, duration: Double?)
    case progress(fraction: Double, downloaded: Int64, total: Int64, speed: Int64, eta: Int?, recordedSeconds: Double?)
    case process(stage: String)
    case done(path: String, size: Int64, seconds: Double)
    case stopped
    case error(message: String)
}

public struct SelectedStreams: Sendable {
    public var video: MediaFormat?
    public var audio: MediaFormat?

    public var primary: MediaFormat { (video ?? audio)! }
    public var displayQuality: String {
        if let v = video { return v.displayQuality }
        return audio?.displayQuality ?? "Audio"
    }
}

public enum FormatSelector {

    public static func select(from formats: [MediaFormat], options: DownloadRequestOptions) throws -> SelectedStreams {
        guard !formats.isEmpty else {
            throw NSError(domain: "FormatSelector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No playable media streams found at this link."])
        }

        // 1. Explicit `-f id1+id2` or `-f id`
        if let explicit = options.formatSelector, !explicit.isEmpty {
            let parts = explicit.split(separator: "+").map(String.init)
            if parts.count == 2 {
                guard let v = formats.first(where: { $0.id == parts[0] }),
                      let a = formats.first(where: { $0.id == parts[1] }) else {
                    throw NSError(domain: "FormatSelector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Requested format IDs '\(explicit)' not available."])
                }
                return SelectedStreams(video: v, audio: a)
            } else if let single = formats.first(where: { $0.id == explicit }) {
                if single.hasVideo && !single.hasAudio {
                    let bestA = pickBestAudio(from: formats, preferAAC: options.preferCompatible || single.ext == "mp4")
                    return SelectedStreams(video: single, audio: bestA)
                }
                return single.hasVideo ? SelectedStreams(video: single, audio: nil) : SelectedStreams(video: nil, audio: single)
            } else {
                throw NSError(domain: "FormatSelector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Format '\(explicit)' not found (run `ubit formats <url>` to list IDs)."])
            }
        }

        // 2. Audio-only mode (`-a` / `--mp3`)
        if options.audioOnly {
            if let a = pickBestAudio(from: formats, preferAAC: options.preferCompatible) {
                return SelectedStreams(video: nil, audio: a)
            }
            // Fallback: muxed stream and strip video track during MP4 mux
            return SelectedStreams(video: nil, audio: formats.first)
        }

        // 3. Video mode with max quality ceiling + codec preference
        let maxHeight = Int(options.maxQuality) // nil if "best"
        let videoCandidates = formats.filter { $0.hasVideo }
        guard !videoCandidates.isEmpty else {
            return SelectedStreams(video: nil, audio: pickBestAudio(from: formats, preferAAC: options.preferCompatible) ?? formats[0])
        }

        let withinCeiling = videoCandidates.filter { f in
            guard let mh = maxHeight, let h = f.height, h > 0 else { return true }
            return h <= mh
        }
        let pool = withinCeiling.isEmpty ? videoCandidates : withinCeiling

        let ranked = pool.sorted { lhs, rhs in
            if options.preferCompatible {
                // Prefer native ISO-BMFF MP4 / HLS containers (avc1, hvc1, av01) over WebM so zero-FFmpeg muxing & QuickTime work at full 1080p/4K
                if lhs.isNativeMP4 != rhs.isNativeMP4 { return lhs.isNativeMP4 }
            }
            let lh = lhs.height ?? 0
            let rh = rhs.height ?? 0
            if lh != rh { return lh > rh }
            let lfps = Int((lhs.fps ?? 30).rounded())
            let rfps = Int((rhs.fps ?? 30).rounded())
            if lfps != rfps { return lfps > rfps }
            if options.preferCompatible && lhs.isH264 != rhs.isH264 {
                // At identical resolution & fps, prefer H.264 for broadest hardware decode compatibility
                return lhs.isH264
            }
            let lbr = lhs.bitrate ?? lhs.filesize ?? 0
            let rbr = rhs.bitrate ?? rhs.filesize ?? 0
            if lbr != rbr { return lbr > rbr }
            return lhs.hasAudio && !rhs.hasAudio
        }
        let chosenVideo = ranked[0]
        if chosenVideo.hasAudio {
            return SelectedStreams(video: chosenVideo, audio: nil)
        }

        let wantAAC = options.preferCompatible || chosenVideo.ext == "mp4" || chosenVideo.isH264
        let chosenAudio = pickBestAudio(from: formats, preferAAC: wantAAC)
        return SelectedStreams(video: chosenVideo, audio: chosenAudio)
    }

    public static func pickBestAudio(from formats: [MediaFormat], preferAAC: Bool) -> MediaFormat? {
        let audioOnly = formats.filter { $0.hasAudio && !$0.hasVideo }
        guard !audioOnly.isEmpty else { return nil }
        return audioOnly.sorted { lhs, rhs in
            if preferAAC && lhs.isAAC != rhs.isAAC { return lhs.isAAC }
            return (lhs.bitrate ?? lhs.filesize ?? 0) > (rhs.bitrate ?? rhs.filesize ?? 0)
        }.first
    }
}

private actor SpeedMeter {
    private var samples: [(t: TimeInterval, bytes: Int64)] = []
    private var lastEmit: TimeInterval = 0

    func update(downloaded: Int64, total: Int64, force: Bool = false) -> (shouldEmit: Bool, speed: Int64, eta: Int?) {
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, downloaded))
        samples.removeAll { now - $0.t > 3.0 }
        if !force && now - lastEmit < 0.12 {
            return (false, 0, nil)
        }
        lastEmit = now
        var speed: Int64 = 0
        if let oldest = samples.first, now - oldest.t > 0.08, downloaded >= oldest.bytes {
            speed = Int64(Double(downloaded - oldest.bytes) / (now - oldest.t))
        }
        let eta: Int? = (speed > 0 && total > downloaded) ? Int((total - downloaded) / speed) : nil
        return (true, speed, eta)
    }
}

public final class DownloadEngine: @unchecked Sendable {
    public init() {}

    public func makeClient(settings: Settings, options: DownloadRequestOptions) -> HTTPClient {
        let cookies = CookieVault.load(source: options.cookieSource)
        var extra = options.extraHeaders
        if let ref = options.referer, !ref.isEmpty { extra["Referer"] = ref }
        let rate = FormatHelpers.parseRateLimit(options.rateLimit ?? settings.rateLimit)
        return HTTPClient(
            cookies: cookies,
            proxy: options.proxy ?? (settings.proxy.isEmpty ? nil : settings.proxy),
            rateLimitBytesPerSec: rate,
            userAgent: options.userAgent,
            extraHeaders: extra
        )
    }

    public func extract(url: String, settings: Settings, options: DownloadRequestOptions) async throws -> MediaInfo {
        let client = makeClient(settings: settings, options: options)
        return try await ExtractorRegistry.extract(url: url, client: client)
    }

    /// Executes a complete single-item download, muxing, SponsorBlock, subtitles, metadata, and conversion pipeline.
    public func downloadSingle(
        url: String,
        preExtracted: MediaInfo? = nil,
        settings: Settings,
        options: DownloadRequestOptions,
        shouldStopLive: (@Sendable () -> Bool)? = nil,
        onEvent: (@Sendable (DownloadEventPayload) -> Void)? = nil
    ) async throws -> URL {
        let startedTime = ProcessInfo.processInfo.systemUptime
        try AppPaths.ensureAppSupport()
        onEvent?(.start(url: url))

        let client = makeClient(settings: settings, options: options)
        var info: MediaInfo
        if let pre = preExtracted, !pre.formats.isEmpty {
            info = pre
        } else {
            info = try await ExtractorRegistry.extract(url: url, client: client)
        }

        if info.isDRM && info.formats.isEmpty {
            throw NSError(domain: "DownloadEngine", code: 40, userInfo: [NSLocalizedDescriptionKey: "This media is protected by DRM and can't be downloaded."])
        }
        if let customTitle = options.customTitle, !customTitle.isEmpty {
            info.title = customTitle
        }

        var selected = try FormatSelector.select(from: info.formats, options: options)
        let isAudioOut = options.audioOnly || (selected.video == nil)
        let targetExt: String
        if let tf = options.targetFormat, !tf.isEmpty {
            targetExt = tf.lowercased()
        } else if isAudioOut {
            targetExt = settings.audioFormat.lowercased()
        } else {
            // If user explicitly picked non-MP4 codec without compatible mode & without ffmpeg, preserve webm if single file
            if !options.preferCompatible, selected.video?.ext == "webm", selected.audio?.ext == "webm" || selected.audio == nil, settings.videoFormat == "mp4", MediaConverter.findSystemFFmpeg() == nil {
                targetExt = "webm"
            } else {
                targetExt = settings.videoFormat.lowercased()
            }
        }

        // Compute output path from template & folder rules
        var baseDir = URL(fileURLWithPath: ((options.outputDir ?? settings.folder) as NSString).expandingTildeInPath, isDirectory: true)
        if settings.siteFolders && !info.site.isEmpty {
            baseDir.appendPathComponent(FormatHelpers.sanitizeFilename(info.site), isDirectory: true)
        }
        if settings.playlistFolders, let plTitle = options.playlistTitle, !plTitle.isEmpty {
            baseDir.appendPathComponent(FormatHelpers.sanitizeFilename(plTitle), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let relName = FormatHelpers.renderTemplate(
            options.filenameTemplate ?? settings.template,
            info: info,
            quality: selected.displayQuality,
            ext: targetExt
        )
        let finalURL = uniqueDestinationURL(baseDir.appendingPathComponent(relName))

        onEvent?(.info(
            title: info.title,
            site: info.site,
            quality: selected.displayQuality,
            ext: targetExt,
            path: finalURL.path,
            isLive: info.isLive || selected.primary.isLive,
            thumbnail: info.thumbnail,
            duration: info.duration
        ))

        // Work files inside ~/Library/Application Support/uBit/work/<hash>
        let workID = String(UUID().uuidString.prefix(12)).lowercased()
        let itemWorkDir = AppPaths.workDir.appendingPathComponent(workID, isDirectory: true)
        try FileManager.default.createDirectory(at: itemWorkDir, withIntermediateDirectories: true)
        defer {
            // Clean up temp work dir on success (keep .part in destination parent when interrupted for HTTP resume!)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try? FileManager.default.removeItem(at: itemWorkDir)
            }
        }

        let vTemp = finalURL.deletingLastPathComponent().appendingPathComponent(".\(finalURL.deletingPathExtension().lastPathComponent).v.\(selected.video?.ext ?? "mp4")")
        let aTemp = finalURL.deletingLastPathComponent().appendingPathComponent(".\(finalURL.deletingPathExtension().lastPathComponent).a.\(selected.audio?.ext ?? "m4a")")

        let meter = SpeedMeter()
        let vEstSize = selected.video?.filesize ?? 0
        let aEstSize = selected.audio?.filesize ?? 0
        let combinedEst = vEstSize + aEstSize

        // Helper that downloads one MediaFormat (with stale-URL refresh on 403/410!)
        var videoSectionBaseSec: Double = 0
        var audioSectionBaseSec: Double = 0
        var videoIsTS = false
        var audioIsTS = false

        func fetchStream(_ fmt: MediaFormat, to dest: URL, priorBytes: Int64, isVideoRole: Bool) async throws -> (baseSec: Double, isTS: Bool) {
            var currentFmt = fmt
            var blockedFormatIDs = Set<String>()
            for refreshAttempt in 0..<3 {
                do {
                    return try await fetchStreamOnce(currentFmt, to: dest, priorBytes: priorBytes, isVideoRole: isVideoRole)
                } catch HTTPError.staleLink {
                    guard refreshAttempt < 2 else { throw HTTPError.staleLink(403) }
                    if refreshAttempt == 1 {
                        blockedFormatIDs.insert(currentFmt.id)
                        try? FileManager.default.removeItem(at: dest.appendingPathExtension("part"))
                        try? FileManager.default.removeItem(at: dest.appendingPathExtension("part.json"))
                    }
                    let freshInfo = try await ExtractorRegistry.extract(url: url, client: client)
                    let remaining = freshInfo.formats.filter { !blockedFormatIDs.contains($0.id) }
                    let candidatePool = remaining.isEmpty ? freshInfo.formats : remaining
                    let freshSel = try FormatSelector.select(from: candidatePool, options: options)
                    if let updated = isVideoRole ? freshSel.video : (freshSel.audio ?? freshSel.video) {
                        currentFmt = updated
                        selected = freshSel
                        continue
                    }
                    throw HTTPError.staleLink(403)
                }
            }
            return (0, false)
        }

        func fetchStreamOnce(_ fmt: MediaFormat, to dest: URL, priorBytes: Int64, isVideoRole: Bool) async throws -> (baseSec: Double, isTS: Bool) {
            var mergedHeaders = fmt.headers ?? [:]
            if let ref = options.referer, mergedHeaders["Referer"] == nil { mergedHeaders["Referer"] = ref }

            switch fmt.proto {
            case .hls:
                let (isFMP4, _) = try await HLSEngine.downloadStream(
                    client: client,
                    playlistURL: fmt.url,
                    destination: dest,
                    headers: mergedHeaders,
                    section: options.section,
                    connections: options.connections,
                    shouldStopLive: shouldStopLive
                ) { done, est, frac, recSec in
                    Task {
                        let tot = max(combinedEst, priorBytes + est)
                        let upd = await meter.update(downloaded: priorBytes + done, total: tot)
                        if upd.shouldEmit {
                            onEvent?(.progress(
                                fraction: fmt.isLive ? 0 : frac,
                                downloaded: priorBytes + done,
                                total: tot,
                                speed: upd.speed,
                                eta: upd.eta,
                                recordedSeconds: fmt.isLive ? recSec : nil
                            ))
                        }
                    }
                }
                return (0, !isFMP4)

            case .dash:
                try await DASHEngine.downloadRepresentation(
                    client: client,
                    mpdURL: fmt.url,
                    formatID: fmt.id,
                    destination: dest,
                    headers: mergedHeaders,
                    connections: options.connections
                ) { done, est, frac in
                    Task {
                        let tot = max(combinedEst, priorBytes + est)
                        let upd = await meter.update(downloaded: priorBytes + done, total: tot)
                        if upd.shouldEmit {
                            onEvent?(.progress(fraction: frac, downloaded: priorBytes + done, total: tot, speed: upd.speed, eta: upd.eta, recordedSeconds: nil))
                        }
                    }
                }
                return (0, false)

            case .http:
                // Fast sidx byte-range section download when --section is requested!
                if let sec = options.section, fmt.ext == "mp4" || fmt.ext == "m4a" {
                    if let baseStart = try await tryDownloadSectionViaSidx(client: client, fmt: fmt, headers: mergedHeaders, section: sec, destination: dest) {
                        return (baseStart, false)
                    }
                }

                try await client.downloadFile(
                    url: fmt.url,
                    destination: dest,
                    headers: mergedHeaders,
                    knownSize: fmt.filesize,
                    connections: options.connections
                ) { done, streamTotal in
                    Task {
                        let grandDone = priorBytes + done
                        let grandTotal = combinedEst > 0 ? combinedEst : (priorBytes + streamTotal)
                        let frac = grandTotal > 0 ? min(1.0, Double(grandDone) / Double(grandTotal)) : 0
                        let upd = await meter.update(downloaded: grandDone, total: grandTotal)
                        if upd.shouldEmit {
                            onEvent?(.progress(fraction: frac, downloaded: grandDone, total: grandTotal, speed: upd.speed, eta: upd.eta, recordedSeconds: nil))
                        }
                    }
                }
                return (0, false)
            }
        }

        var vActualBytes: Int64 = 0
        if let vFmt = selected.video {
            let res = try await fetchStream(vFmt, to: vTemp, priorBytes: 0, isVideoRole: true)
            videoSectionBaseSec = res.baseSec
            videoIsTS = res.isTS
            vActualBytes = (try? FileManager.default.attributesOfItem(atPath: vTemp.path)[.size] as? Int64) ?? 0

            // If HLS stream had a separate #EXT-X-MEDIA audio rendition URL and no separate audio format was picked:
            if selected.audio == nil, let hlsAudioURL = vFmt.audioTrackURL {
                let synthAudio = MediaFormat(id: "hls-audio", url: hlsAudioURL, ext: "m4a", proto: .hls, vcodec: "none", acodec: "mp4a", headers: vFmt.headers)
                let aRes = try await fetchStream(synthAudio, to: aTemp, priorBytes: vActualBytes, isVideoRole: false)
                audioSectionBaseSec = aRes.baseSec
                audioIsTS = aRes.isTS
            }
        }
        if let aFmt = selected.audio {
            let res = try await fetchStream(aFmt, to: aTemp, priorBytes: vActualBytes, isVideoRole: false)
            audioSectionBaseSec = res.baseSec
            audioIsTS = res.isTS
        }

        // Fetch cover art, subtitles, and SponsorBlock segments concurrently!
        var coverJPEG: Data?
        if settings.embedMetadata || settings.saveThumbnail, let thumbURL = info.thumbnail, !thumbURL.isEmpty {
            if let (rawImg, _) = try? await client.fetchData(url: thumbURL, includeCookies: false) {
                coverJPEG = MediaConverter.normalizeThumbnailToJPEG(rawImg)
            }
        }

        var downloadedSubTracks: [(lang: String, cues: [(start: Double, end: Double, text: String)])] = []
        if options.downloadSubtitles && !info.subtitles.isEmpty {
            let chosenSubs = chooseSubtitles(available: info.subtitles, langSpec: options.subtitleLangs)
            for sub in chosenSubs {
                if let (subText, _) = try? await client.fetchText(url: sub.url) {
                    let cues = SponsorAndSubtitles.parseSubtitleCues(subText)
                    if !cues.isEmpty { downloadedSubTracks.append((sub.lang, cues)) }
                }
            }
        }

        var sponsorCutIntervals: [(start: Double, end: Double)] = []
        var chapters = info.chapters.isEmpty ? SponsorAndSubtitles.chaptersFromDescription(info.description, totalDuration: info.duration) : info.chapters

        if options.sponsorMode != "keep" && info.site.lowercased() == "youtube" {
            let cats = SponsorAndSubtitles.parseCategories(options.sponsorCategories)
            let segs = await SponsorAndSubtitles.fetchSponsorSegments(client: client, videoID: info.id, categories: cats)
            if options.sponsorMode == "remove" && !segs.isEmpty {
                onEvent?(.process(stage: "Removing sponsors"))
                sponsorCutIntervals = segs.map { ($0.start, $0.end) }
                chapters = SponsorAndSubtitles.squeezeChapters(chapters, removed: sponsorCutIntervals)
                downloadedSubTracks = downloadedSubTracks.map { ($0.lang, SponsorAndSubtitles.squeezeCues($0.cues, removed: sponsorCutIntervals)) }
            } else if options.sponsorMode == "mark" && !segs.isEmpty {
                for s in segs {
                    chapters.append(Chapter(title: "[Sponsor: \(s.category)]", startTime: s.start, endTime: s.end))
                }
                chapters.sort { $0.startTime < $1.startTime }
            }
        }

        // Assemble / Mux container
        onEvent?(.process(stage: "Merging"))
        let intermediateExtension = (isAudioOut ? "m4a" : "mp4")
        let muxOutURL = (targetExt == "mp4" || targetExt == "m4a")
            ? finalURL
            : itemWorkDir.appendingPathComponent("muxed.\(intermediateExtension)")

        let hasVFile = FileManager.default.fileExists(atPath: vTemp.path)
        let hasAFile = FileManager.default.fileExists(atPath: aTemp.path)

        let isRawNonMP4AudioOnly = !hasVFile && hasAFile && ["mp3", "opus", "flac", "wav"].contains(selected.audio?.ext.lowercased() ?? "")
        let canUseNativeMP4Mux = !isRawNonMP4AudioOnly && !((selected.video?.ext == "webm") || (selected.audio?.ext == "webm"))
        if isRawNonMP4AudioOnly {
            let srcAudioExt = selected.audio?.ext.lowercased() ?? "mp3"
            if srcAudioExt == targetExt {
                try FileManager.default.moveItem(at: aTemp, to: finalURL)
            } else if targetExt == "m4a" {
                // Convert raw MP3 -> M4A via native AudioToolbox, then tag with our ISO-BMFF MP4Muxer!
                let rawM4A = itemWorkDir.appendingPathComponent("transcoded.m4a")
                try await MediaConverter.convert(inputURL: aTemp, outputURL: rawM4A, targetFormat: "m4a")
                let aTracks = try MP4Muxer.readTracks(from: rawM4A, sourceIndex: 0)
                let mp4Meta = settings.embedMetadata
                    ? MP4Metadata(title: info.title, artist: info.author, date: info.uploadDate, webpageURL: info.webpageURL, description: info.description, coverJPEG: coverJPEG, chapters: chapters)
                    : MP4Metadata()
                try MP4Muxer.writeMP4(tracks: aTracks, sourceFiles: [rawM4A], destination: finalURL, isAudioOnlyM4A: true, metadata: mp4Meta)
            } else {
                try await MediaConverter.convert(inputURL: aTemp, outputURL: finalURL, targetFormat: targetExt)
            }
        } else if canUseNativeMP4Mux {
            var allTracks: [MP4Track] = []
            var sourceFiles: [URL] = []

            if hasVFile {
                let srcIdx = sourceFiles.count
                sourceFiles.append(vTemp)
                var vt = videoIsTS ? try TSDemuxer.demuxToTracks(tsFileURL: vTemp) : try MP4Muxer.readTracks(from: vTemp, sourceIndex: srcIdx)
                if let sec = options.section {
                    vt = MP4Muxer.trimTracks(vt, section: sec, baseStartTimeSec: videoSectionBaseSec)
                }
                if !sponsorCutIntervals.isEmpty {
                    vt = MP4Muxer.removeIntervals(vt, intervals: sponsorCutIntervals)
                }
                if hasAFile { vt.removeAll { $0.kind == .audio } }
                allTracks.append(contentsOf: vt)
            }

            if hasAFile {
                let srcIdx = sourceFiles.count
                sourceFiles.append(aTemp)
                var at = audioIsTS ? try TSDemuxer.demuxToTracks(tsFileURL: aTemp) : try MP4Muxer.readTracks(from: aTemp, sourceIndex: srcIdx)
                at = at.filter { $0.kind == .audio }
                if let sec = options.section {
                    at = MP4Muxer.trimTracks(at, section: sec, baseStartTimeSec: audioSectionBaseSec)
                }
                if !sponsorCutIntervals.isEmpty {
                    at = MP4Muxer.removeIntervals(at, intervals: sponsorCutIntervals)
                }
                allTracks.append(contentsOf: at)
            }

            let totalDur = allTracks.map(\.durationSeconds).max() ?? info.duration ?? 0
            if !options.externalSubtitles && !isAudioOut {
                for (lang, cues) in downloadedSubTracks {
                    if let subTr = MP4Muxer.makeTimedTextTrack(cues: cues, language: lang, totalDuration: totalDur) {
                        allTracks.append(subTr)
                    }
                }
            }

            let mp4Meta = settings.embedMetadata
                ? MP4Metadata(
                    title: info.title,
                    artist: info.author,
                    date: info.uploadDate,
                    webpageURL: info.webpageURL,
                    description: info.description,
                    coverJPEG: coverJPEG,
                    chapters: chapters
                )
                : MP4Metadata()

            try MP4Muxer.writeMP4(
                tracks: allTracks,
                sourceFiles: sourceFiles,
                destination: muxOutURL,
                isAudioOnlyM4A: isAudioOut,
                metadata: mp4Meta
            )
        } else {
            // WebM VP9/AV1 + Opus path
            if hasVFile && hasAFile {
                try MediaConverter.runFFmpegMux(videoURL: vTemp, audioURL: aTemp, outputURL: finalURL)
            } else if hasVFile {
                try FileManager.default.moveItem(at: vTemp, to: finalURL)
            } else if hasAFile {
                try FileManager.default.moveItem(at: aTemp, to: finalURL)
            }
        }

        try? FileManager.default.removeItem(at: vTemp)
        try? FileManager.default.removeItem(at: aTemp)

        // Optional format conversion (mov, wav, flac, aiff natively; mp3, opus, mkv, webm via ffmpeg)
        if muxOutURL != finalURL && FileManager.default.fileExists(atPath: muxOutURL.path) {
            onEvent?(.process(stage: "Converting to \(targetExt.uppercased())"))
            try await MediaConverter.convert(inputURL: muxOutURL, outputURL: finalURL, targetFormat: targetExt)
        }

        // Write external .vtt subtitle sidecars if requested
        if options.externalSubtitles {
            let base = finalURL.deletingPathExtension().path
            for (lang, cues) in downloadedSubTracks {
                let vttURL = URL(fileURLWithPath: "\(base).\(lang).vtt")
                try? SponsorAndSubtitles.formatWebVTT(cues).write(to: vttURL, atomically: true, encoding: .utf8)
            }
        }

        // Save sidecar .jpg thumbnail if requested
        if settings.saveThumbnail, let jpg = coverJPEG {
            let jpgURL = finalURL.deletingPathExtension().appendingPathExtension("jpg")
            try? jpg.write(to: jpgURL, options: .atomic)
        }

        // macOS Finder WhereFroms + Upload Date + Music/TV library
        MediaConverter.setWhereFroms(fileURL: finalURL, sources: [info.webpageURL, selected.primary.url])
        if settings.useUploadDate {
            MediaConverter.applyUploadDate(info.uploadDate, to: finalURL)
        }
        if settings.addToLibrary {
            MediaConverter.addToAppleMediaLibrary(fileURL: finalURL, isAudio: isAudioOut)
        }

        let finalSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        let elapsed = ProcessInfo.processInfo.systemUptime - startedTime
        onEvent?(.done(path: finalURL.path, size: finalSize, seconds: elapsed))
        return finalURL
    }

    private func tryDownloadSectionViaSidx(
        client: HTTPClient,
        fmt: MediaFormat,
        headers: [String: String],
        section: SectionRange,
        destination: URL
    ) async throws -> Double? {
        let probeEnd = fmt.indexRange?.end ?? 65_535
        let head = try await client.fetchRangeBytes(url: fmt.url, range: ByteRange(start: 0, end: max(32_767, probeEnd)), headers: headers)
        guard let parsed = MP4Muxer.parseSidx(in: head) else { return nil }

        let reqStart = section.start ?? 0
        let reqEnd = section.end ?? .infinity
        let matching = parsed.segments.filter { seg in
            (seg.startTimeSec + seg.durationSec) > reqStart && seg.startTimeSec < reqEnd
        }
        guard let firstSeg = matching.first, let lastSeg = matching.last else { return nil }

        let initBytes = head.prefix(Int(parsed.initEndOffset + 1))
        let bodyRange = ByteRange(start: firstSeg.byteRange.start, end: lastSeg.byteRange.end)
        let bodyBytes = try await client.fetchRangeBytes(url: fmt.url, range: bodyRange, headers: headers)

        var combined = Data(capacity: initBytes.count + bodyBytes.count)
        combined.append(initBytes)
        combined.append(bodyBytes)
        try combined.write(to: destination, options: .atomic)
        return firstSeg.startTimeSec
    }

    private func chooseSubtitles(available: [SubtitleTrack], langSpec: String) -> [SubtitleTrack] {
        let wanted = langSpec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let wantAll = wanted.contains("all") || wanted.isEmpty
        // Group by language, preferring human-written over auto-generated (`!isAutoGenerated`)
        var byLang: [String: SubtitleTrack] = [:]
        for t in available {
            let key = t.lang.lowercased()
            if !wantAll && !wanted.contains(where: { key == $0 || key.hasPrefix($0 + "-") }) {
                continue
            }
            if let existing = byLang[key] {
                if existing.isAutoGenerated && !t.isAutoGenerated { byLang[key] = t }
            } else {
                byLang[key] = t
            }
        }
        return Array(byLang.values)
    }

    private func uniqueDestinationURL(_ candidate: URL) -> URL {
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let dir = candidate.deletingLastPathComponent()
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for n in 2...999 {
            let next = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return candidate
    }
}
