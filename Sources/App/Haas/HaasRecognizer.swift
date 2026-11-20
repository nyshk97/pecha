// Sanami/haas-ja-coreml（Apache-2.0。ThirdParty/haas-ja-coreml/）の swift/Sources/HaasCore/HaasASR.swift を写して変更した。
// 変更: 手元のコンパイル済みのフォルダ（encoder・decoder・joint_enc・joint の .mlmodelc と vocab.json・window.f32・
// mel_filter.f32）から読み込む。定数と窓分けは HaasLayout に移した。計測の項目を減らした。
import CoreML
import Foundation

/// Haas-ja-v1.0 on Core ML: Frontend -> Encoder (int8, fixed 15.04 s window, Neural Engine; longer audio in
/// overlapping windows) -> joint_enc -> TDT greedy decoding with Decoder (KDA) and Joint on the CPU.
/// スレッドセーフではない（HaasModel が専用のキューで 1 本ずつ呼ぶ）
final class HaasRecognizer {
    struct Result {
        let text: String
        let ids: [Int]
    }

    let frontend: HaasFrontend
    let tokenizer: HaasTokenizer
    let encoder, decoder, jointEnc, joint: MLModel
    let stateWidth: Int

    /// `dir`: 手元のコンパイル済みのフォルダ
    init(dir: URL) throws {
        frontend = try HaasFrontend(window: HaasFrontend.readFloats(dir.appendingPathComponent("window.f32")),
                                    melFilter: HaasFrontend.readFloats(dir.appendingPathComponent("mel_filter.f32")))
        tokenizer = try HaasTokenizer(vocabJSON: Data(contentsOf: dir.appendingPathComponent("vocab.json")))
        guard tokenizer.count == HaasLayout.vocabSize else { throw PechaError("vocab.json の語の数が \(tokenizer.count)") }
        let enc = MLModelConfiguration(); enc.computeUnits = .cpuAndNeuralEngine
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        func model(_ name: String, _ config: MLModelConfiguration) throws -> MLModel {
            try MLModel(contentsOf: dir.appendingPathComponent("\(name).mlmodelc"), configuration: config)
        }
        encoder = try model("encoder", enc)
        decoder = try model("decoder", cpu)
        jointEnc = try model("joint_enc", cpu)
        joint = try model("joint", cpu)
        guard let width = decoder.modelDescription.inputDescriptionsByName["rec"]?.multiArrayConstraint?.shape.last?.intValue
        else { throw PechaError("decoder の rec の形が読めない") }
        stateWidth = width
    }

    /// `audio`: 16kHz・1ch・Float32
    func transcribe(_ audio: [Float]) throws -> Result {
        let (mel, L) = frontend(audio)
        guard L > 0 else { return Result(text: "", ids: []) }
        let f = try encode(mel: mel, L: L)   // [T][640] projected encoder frames
        let ids = try decode(f)
        return Result(text: tokenizer.decode(ids), ids: ids)
    }

    // MARK: - encoder

    func encode(mel: [Float], L: Int) throws -> [[Float]] {
        let nM = HaasFrontend.nMels, W = HaasLayout.window, sub = HaasLayout.sub
        let x = try MLMultiArray(shape: [1, NSNumber(value: nM), NSNumber(value: W)], dataType: .float32)
        let len = try MLMultiArray(shape: [1], dataType: .int32)
        var frames = [[Float]]()
        for chunk in HaasLayout.chunks(L) {
            let start = chunk.start
            let n = min(W, L - start)
            let xp = x.dataPointer.bindMemory(to: Float.self, capacity: nM * W)
            let s0 = x.strides[1].intValue, s1 = x.strides[2].intValue
            for m in 0..<nM { for t in 0..<W { xp[m * s0 + t * s1] = t < n ? mel[(start + t) * nM + m] : 0 } }
            len[0] = NSNumber(value: Int32(n))
            let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio_signal": x, "length": len]))
            guard let encoded = out.featureValue(for: "encoded")?.multiArrayValue else { throw PechaError("encoder の出力が無い") }
            let proj = try jointEnc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["encoded": encoded]))
            guard let fa = proj.featureValue(for: "f")?.multiArrayValue else { throw PechaError("joint_enc の出力が無い") }
            let a = (chunk.keepFrom - start) / sub, b = (chunk.keepTo - start + sub - 1) / sub
            frames += Self.rows(fa, a..<b)
        }
        return frames
    }

    static func rows(_ m: MLMultiArray, _ r: Range<Int>) -> [[Float]] {
        let D = m.shape[2].intValue, st1 = m.strides[1].intValue, st2 = m.strides[2].intValue
        return r.map { t in
            (0..<D).map { d -> Float in
                let i = t * st1 + d * st2
                switch m.dataType {
                case .float16: return Float(m.dataPointer.bindMemory(to: Float16.self, capacity: i + 1)[i])
                default: return m.dataPointer.bindMemory(to: Float.self, capacity: i + 1)[i]
                }
            }
        }
    }

    // MARK: - TDT greedy decoding (same rule as haas_ort.greedy_tdt / NeMo label looping)

    func decode(_ f: [[Float]]) throws -> [Int] {
        let T = f.count, D = HaasLayout.jointWidth
        var rec = try MLMultiArray(shape: [2, 1, NSNumber(value: stateWidth)], dataType: .float32)
        var conv = try MLMultiArray(shape: [2, 1, NSNumber(value: stateWidth)], dataType: .float32)
        for a in [rec, conv] { memset(a.dataPointer, 0, stateWidth * 2 * 4) }
        let tok = try MLMultiArray(shape: [1], dataType: .int32)
        let fIn = try MLMultiArray(shape: [1, NSNumber(value: D)], dataType: .float32)

        func pred(_ k: Int) throws -> MLMultiArray {
            tok[0] = NSNumber(value: Int32(k))
            let o = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["token": tok, "rec": rec, "conv": conv]))
            guard let r = o.featureValue(for: "rec_out")?.multiArrayValue, let c = o.featureValue(for: "conv_out")?.multiArrayValue,
                  let g = o.featureValue(for: "g")?.multiArrayValue else { throw PechaError("decoder の出力が無い") }
            rec = r
            conv = c
            return g
        }
        // dec(last, s) gives g and the state after `last`; the state advances only on emission
        var g = try pred(HaasLayout.blank)
        var tokens = [Int](), t = 0, lastTs = -1, count = 0
        while t < T {
            var k = HaasLayout.blank, tLabel = t
            while true {
                f[t].withUnsafeBufferPointer { fIn.dataPointer.bindMemory(to: Float.self, capacity: D).update(from: $0.baseAddress!, count: D) }
                let o = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: ["f": fIn, "g": g]))
                guard let tokenID = o.featureValue(for: "token_id")?.multiArrayValue,
                      let durationID = o.featureValue(for: "duration_id")?.multiArrayValue else { throw PechaError("joint の出力が無い") }
                k = tokenID[0].intValue
                let di = durationID[0].intValue
                guard HaasLayout.durations.indices.contains(di) else { throw PechaError("joint の duration_id が \(di)") }
                var d = HaasLayout.durations[di]
                if k == HaasLayout.blank && d == 0 { d = 1 }
                tLabel = t; t += d
                if k != HaasLayout.blank || t >= T { break }
            }
            if k != HaasLayout.blank {
                tokens.append(k)
                count = tLabel == lastTs ? count + 1 : 1
                lastTs = tLabel
                g = try pred(k)
                if count >= HaasLayout.maxSymbols && lastTs == t { t += 1 }
            }
        }
        return tokens
    }
}
