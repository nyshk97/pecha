# haas-ja-coreml（Sanami）から写したコード

Pecha の Haas の認識は、[Sanami/haas-ja-coreml](https://huggingface.co/Sanami/haas-ja-coreml)（版 `62f542657b454afa7873424e3dfb6d7a1d9c270d`）の
Swift の実装を写して変更したもの。元のコードは Apache License 2.0（このフォルダの `LICENSE`・`NOTICE`）。

| 元のファイル | 写した先 | 変えたこと |
|---|---|---|
| `swift/Sources/HaasCore/Frontend.swift` | `Sources/Core/Haas/HaasFrontend.swift` | 定数を `frontend.bin` でなく okayuji 版の `window.f32`・`mel_filter.f32` から受け取る |
| `swift/Sources/HaasCore/Tokenizer.swift` | `Sources/Core/Haas/HaasTokenizer.swift` | 語の一覧を配列で受け取る。未知語（id 0）を捨てる |
| `swift/Sources/HaasCore/HaasASR.swift` | `Sources/Core/Haas/HaasLayout.swift`（定数・窓分け）と `Sources/App/Haas/HaasRecognizer.swift`（Core ML を呼ぶ部分） | 手元のコンパイル済みのフォルダから読み込む。定数と窓分けを切り離した。計測の項目を減らした |

モデル（重み）はリポジトリに入れていない。iCloud Drive の `Pecha/models/` に、okayuji 版
（[okayuji/Haas-ja-v1.0-CoreML-INT8](https://huggingface.co/okayuji/Haas-ja-v1.0-CoreML-INT8)。Apache License 2.0。
元は [third-intelligence/Haas-ja-v1.0](https://huggingface.co/third-intelligence/Haas-ja-v1.0)）を
`scripts/place-haas-model.py` で置く。ライセンスの文書はモデルのフォルダに一緒に入っている。
