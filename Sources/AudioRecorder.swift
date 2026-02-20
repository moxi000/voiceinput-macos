import AVFoundation
import Foundation

/// Records microphone audio as 16kHz 16-bit mono PCM data chunks.
class AudioRecorder {
    private let engine = AVAudioEngine()
    private var isRecording = false
    private var pcmBuffer = Data()

    /// Callback with PCM data chunks during recording
    var onAudioChunk: ((Data) -> Void)?

    /// Callback with normalized audio level (0.0 – 1.0) for waveform visualization
    var onAudioLevel: ((Float) -> Void)?

    /// Start recording from the default input device
    func start() throws {
        guard !isRecording else { return }

        // Ensure clean state: remove any leftover tap and reset engine
        // This prevents ObjC exception on re-start after error/timeout
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input available (sampleRate=\(hardwareFormat.sampleRate))"])
        }

        // Target: 16kHz, mono, 16-bit integer PCM
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create target format"])
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }

        pcmBuffer = Data()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Convert to 16kHz mono PCM Int16
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hardwareFormat.sampleRate
            )
            guard frameCapacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            if let channelData = convertedBuffer.int16ChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                let byteCount = frameCount * 2 // 16-bit = 2 bytes
                let data = Data(bytes: channelData[0], count: byteCount)
                self.pcmBuffer.append(data)
                self.onAudioChunk?(data)

                // Compute normalized RMS level for waveform visualization
                if frameCount > 0 {
                    let samples = channelData[0]
                    var sum: Float = 0
                    for i in 0..<frameCount {
                        let s = Float(samples[i])
                        sum += s * s
                    }
                    let rms = sqrtf(sum / Float(frameCount))
                    let normalized = min(rms / 8000.0, 1.0) // normalize to 0-1
                    self.onAudioLevel?(normalized)
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        print("[AudioRecorder] Started recording (16kHz mono PCM)")
    }

    /// Stop recording and return all accumulated PCM data
    func stop() -> Data {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
            print("[AudioRecorder] Stopped, \(pcmBuffer.count) bytes PCM (\(String(format: "%.1f", Double(pcmBuffer.count) / 32000.0))s)")
        }
        let result = pcmBuffer
        pcmBuffer = Data()
        return result
    }

    var recording: Bool { isRecording }
}
