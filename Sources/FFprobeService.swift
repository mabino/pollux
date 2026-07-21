import Foundation

struct ProbeResult: Sendable {
    let kind: StreamKind?
    let bitRate: Int64
    let hasVideo: Bool
    let hasAudio: Bool
    let hasPotentialVideo: Bool

    var playable: Bool {
        hasVideo && hasAudio
    }
}

func acceptsProbeResult(_ result: ProbeResult, for kind: StreamKind) -> Bool {
    if result.playable {
        return true
    }

    return kind == .hls && result.hasAudio && result.hasPotentialVideo
}

func probeResultNotice(_ result: ProbeResult, for kind: StreamKind) -> String? {
    guard !result.playable, kind == .hls, result.hasAudio, result.hasPotentialVideo else {
        return nil
    }
    return "Pollux is using an HLS stream whose audio is confirmed but whose video dimensions were not fully known during probing."
}

final class FFprobeService: @unchecked Sendable {
    private let executableURL: URL

    init() throws {
        guard let executableURL = locateExecutable(
            envName: "POLLUX_FFPROBE_PATH",
            defaultsKey: PolluxPreferences.ffprobePathKey,
            fallbackNames: ["ffprobe"]
        ) else {
            throw PolluxError.ffprobeMissing
        }
        self.executableURL = executableURL
    }

    func probe(candidate: StreamCandidate) async throws -> ProbeResult {
        let task = Task.detached(priority: .userInitiated) { [executableURL] in
            let process = Process()
            process.executableURL = executableURL

            var arguments = [
                "-v", "error",
                "-print_format", "json",
                "-show_entries", "format=format_name,bit_rate:stream=codec_type,codec_name,width,height",
            ]

            let formattedHeaders = formatHTTPHeaders(candidate.headers)
            if !formattedHeaders.isEmpty {
                arguments.append(contentsOf: ["-headers", formattedHeaders])
            }

            arguments.append(contentsOf: [
                "-allowed_extensions", "ALL",
                "-allowed_segment_extensions", "ALL",
                "-extension_picky", "0",
                "-seg_format_options", "extension_picky=0",
                candidate.url.absoluteString,
            ])
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0 else {
                let reason = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw PolluxError.unexpected(reason.isEmpty ? "ffprobe failed for \(candidate.url.absoluteString)" : reason)
            }

            let decoded = try JSONDecoder().decode(FFprobeEnvelope.self, from: stdoutData)
            guard !decoded.format.formatName.isEmpty else {
                throw PolluxError.unexpected("ffprobe returned no format for \(candidate.url.absoluteString)")
            }

            let kind = StreamKind.fromFFprobeFormat(decoded.format.formatName)
            let bitRate = Int64(decoded.format.bitRate ?? "") ?? 0

            var hasVideo = false
            var hasAudio = false
            var hasPotentialVideo = false
            for stream in decoded.streams {
                switch stream.codecType {
                case "video":
                    if !imageCodecs.contains(stream.codecName?.lowercased() ?? "") {
                        hasPotentialVideo = true
                    }
                    let width = stream.width ?? 0
                    let height = stream.height ?? 0
                    if width > 0, height > 0, !imageCodecs.contains(stream.codecName?.lowercased() ?? "") {
                        hasVideo = true
                    }
                case "audio":
                    hasAudio = true
                default:
                    continue
                }
            }

            return ProbeResult(
                kind: kind,
                bitRate: bitRate,
                hasVideo: hasVideo,
                hasAudio: hasAudio,
                hasPotentialVideo: hasPotentialVideo
            )
        }
        return try await task.value
    }
}

private struct FFprobeEnvelope: Decodable {
    struct Format: Decodable {
        let bitRate: String?
        let formatName: String

        enum CodingKeys: String, CodingKey {
            case bitRate = "bit_rate"
            case formatName = "format_name"
        }
    }

    struct Stream: Decodable {
        let codecType: String?
        let codecName: String?
        let width: Int?
        let height: Int?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case width
            case height
        }
    }

    let streams: [Stream]
    let format: Format
}

private let imageCodecs: Set<String> = [
    "png", "apng", "mjpeg", "jpeg", "jpegls", "bmp", "gif", "tiff", "webp", "ppm",
]

private func formatHTTPHeaders(_ headers: [String: String]) -> String {
    headers
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        .filter { !$0.key.hasPrefix(":") }
        .map { "\($0.key): \($0.value)\r\n" }
        .joined()
}
