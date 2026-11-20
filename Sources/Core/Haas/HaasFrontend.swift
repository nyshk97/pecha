// Sanami/haas-ja-coreml（Apache-2.0。ThirdParty/haas-ja-coreml/）の swift/Sources/HaasCore/Frontend.swift を写して変更した。
// 変更: 定数を frontend.bin でなく okayuji 版の window.f32・mel_filter.f32 の中身から受け取る。名前を HaasFrontend にした。
import Accelerate
import Foundation

/// NeMo AudioToMelSpectrogramPreprocessor as in the Haas-ja-v1.0 checkpoint (eval, no dither):
/// preemphasis 0.97, 512-point STFT (center, zero padding) with the checkpoint's 400-sample window,
/// power spectrum, 128-bin slaney filterbank, log(x + 2^-24), per-feature normalization over the
/// whole utterance (unbiased std + 1e-5). seq_len = samples / 160 (NeMo's get_seq_len, no +1).
final class HaasFrontend {
    static let hop = 160, nFFT = 512, nMels = 128, nBins = 257, winLength = 400
    let window: [Float]   // 512, the 400-sample window centered as torch.stft pads it
    let fbT: [Float]      // [257, 128]
    let dft: vDSP.DFT<Float>

    struct InvalidConstants: Error, CustomStringConvertible {
        let description: String
    }

    /// `window`: window.f32 の 400 個。`melFilter`: mel_filter.f32 の [128, 257]（行優先）
    init(window w400: [Float], melFilter fb: [Float]) throws {
        guard w400.count == Self.winLength else { throw InvalidConstants(description: "window.f32 の数が \(w400.count)") }
        guard fb.count == Self.nMels * Self.nBins else { throw InvalidConstants(description: "mel_filter.f32 の数が \(fb.count)") }
        var w = [Float](repeating: 0, count: Self.nFFT)
        let off = (Self.nFFT - Self.winLength) / 2
        for i in 0..<Self.winLength { w[off + i] = w400[i] }
        window = w
        var t = [Float](repeating: 0, count: Self.nBins * Self.nMels)
        for m in 0..<Self.nMels {
            for b in 0..<Self.nBins { t[b * Self.nMels + m] = fb[m * Self.nBins + b] }
        }
        fbT = t
        dft = vDSP.DFT(count: Self.nFFT, direction: .forward, transformType: .complexReal, ofType: Float.self)!
    }

    /// little-endian の float32 が並んだファイルを読む
    static func readFloats(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Returns the normalized log-mel, frame-major [seqLen][128], and seqLen.
    func callAsFunction(_ audio: [Float]) -> (mel: [Float], seqLen: Int) {
        let n = audio.count, hop = Self.hop, nFFT = Self.nFFT, nM = Self.nMels, nB = Self.nBins
        let seqLen = n / hop
        guard seqLen > 1 else { return ([], 0) }
        // preemphasis, then center padding of nFFT/2 zeros on both sides
        var x = [Float](repeating: 0, count: n + nFFT)
        x[nFFT / 2] = audio[0]
        for i in 1..<n { x[nFFT / 2 + i] = audio[i] - 0.97 * audio[i - 1] }
        var mel = [Float](repeating: 0, count: seqLen * nM)
        let block = 512
        var power = [Float](repeating: 0, count: block * nB)
        var frame = [Float](repeating: 0, count: nFFT)
        var inR = [Float](repeating: 0, count: nFFT / 2), inI = inR
        var outR = inR, outI = inR
        var t0 = 0
        while t0 < seqLen {
            let nt = min(block, seqLen - t0)
            for j in 0..<nt {
                let s = (t0 + j) * hop
                x.withUnsafeBufferPointer { xp in
                    vDSP.multiply(UnsafeBufferPointer(rebasing: xp[s..<s + nFFT]), window, result: &frame)
                }
                for k in 0..<nFFT / 2 { inR[k] = frame[2 * k]; inI[k] = frame[2 * k + 1] }
                dft.transform(inputReal: inR, inputImaginary: inI, outputReal: &outR, outputImaginary: &outI)
                // vDSP's real forward DFT is 2x the mathematical one; DC in outR[0], Nyquist packed in outI[0]
                let p = j * nB
                power[p] = 0.25 * outR[0] * outR[0]
                power[p + nB - 1] = 0.25 * outI[0] * outI[0]
                for k in 1..<nFFT / 2 { power[p + k] = 0.25 * (outR[k] * outR[k] + outI[k] * outI[k]) }
            }
            // mel[t0..<t0+nt] = power[nt, 257] x fbT[257, 128]
            power.withUnsafeBufferPointer { pp in
                fbT.withUnsafeBufferPointer { fp in
                    mel.withUnsafeMutableBufferPointer { mp in
                        vDSP_mmul(pp.baseAddress!, 1, fp.baseAddress!, 1, mp.baseAddress! + t0 * nM, 1,
                                  vDSP_Length(nt), vDSP_Length(nM), vDSP_Length(nB))
                    }
                }
            }
            t0 += nt
        }
        let eps = Float(pow(2.0, -24.0))
        for i in 0..<mel.count { mel[i] = logf(mel[i] + eps) }
        // per-feature mean / unbiased std over the seqLen frames
        var mean = [Double](repeating: 0, count: nM), sq = [Double](repeating: 0, count: nM)
        for t in 0..<seqLen { for m in 0..<nM { mean[m] += Double(mel[t * nM + m]) } }
        for m in 0..<nM { mean[m] /= Double(seqLen) }
        for t in 0..<seqLen { for m in 0..<nM { let d = Double(mel[t * nM + m]) - mean[m]; sq[m] += d * d } }
        let mf = mean.map { Float($0) }
        let inv = sq.map { Float(1.0 / ((($0 / Double(seqLen - 1))).squareRoot() + 1e-5)) }
        for t in 0..<seqLen { for m in 0..<nM { mel[t * nM + m] = (mel[t * nM + m] - mf[m]) * inv[m] } }
        return (mel, seqLen)
    }
}
