// chunks は Sanami/haas-ja-coreml（Apache-2.0。ThirdParty/haas-ja-coreml/）の swift/Sources/HaasCore/HaasASR.swift から写した。
// 変更: 定数と窓分けを、Core ML を呼ぶ部分から切り離してここに集めた（テストで確かめるため）。時間切れの計算を足した。
import Foundation

/// Haas-ja-v1.0 の Core ML 版の形の定数（okayuji 版の frontend.json と同じ値。読み込み時に照合する）
enum HaasLayout {
    static let sampleRate = 16000
    /// encoder の固定の窓（メルフレーム）。15.04 秒
    static let window = 1504
    /// 長い音声を窓に分けるとき、内側の端で捨てるフレーム数（2.08 秒）
    static let context = 208
    /// encoder の間引き（8 メルフレームで 1 フレーム）
    static let sub = 8
    static let encFrames = 188
    static let blank = 3072
    static let durations = [0, 1, 2, 3, 4]
    static let maxSymbols = 10
    static let vocabSize = 3072
    static let jointWidth = 640

    struct Chunk: Equatable {
        /// 窓の先頭（メルフレーム）
        let start: Int
        /// 窓のうち使う範囲 [keepFrom, keepTo)
        let keepFrom: Int
        let keepTo: Int
    }

    /// 長さ L（メルフレーム）を窓に分ける。使う範囲は [0, L) を隙間なく覆い、境目は `sub` の倍数になる
    static func chunks(_ L: Int) -> [Chunk] {
        if L <= window { return [Chunk(start: 0, keepFrom: 0, keepTo: L)] }
        var out = [Chunk](), keep = 0
        let last = (L - window + sub - 1) / sub * sub
        while keep < L {
            let start = max(0, min(keep - context, last))
            let end = start >= last ? L : start + window - context
            out.append(Chunk(start: start, keepFrom: keep, keepTo: end))
            keep = end
        }
        return out
    }

    /// 認識をこの秒数で打ち切ってOSの認識に回す。普段は 30 秒の音声で 0.1 秒ほどなので、
    /// Neural Engine が詰まったときだけ当たる長さにする
    static func timeout(audioSeconds: Double) -> Double {
        5 + audioSeconds * 0.25
    }
}
