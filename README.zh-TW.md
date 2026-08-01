# SpeakNote

**在 Mac 上，把語音直接變成可用文字與結構化 Markdown。**

[![CI](https://github.com/nnnc8/SpeakNote/actions/workflows/ci.yml/badge.svg)](https://github.com/nnnc8/SpeakNote/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#相容性)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[下載最新可用版本](https://github.com/nnnc8/SpeakNote/releases/latest) · [English](README.md) · [文件網站](https://nnnc8.github.io/SpeakNote/)

![SpeakNote 快速聽寫與語音筆記](.github/assets/speaknote-hero.png)

> **發行狀態：** v0.1.0 是目前的原始碼版本。本專案尚未宣稱已發布完成簽署與
> 公證的公開版本。如果 Releases 頁面沒有下載檔案，請從原始碼建置，或稍後再查看。

SpeakNote 是原生 macOS App，可用於快速聽寫、長時間錄音、匯入音訊與整理結構化
筆記。支援條件允許時可使用裝置端 Apple Speech；選用 Groq Cloud 前，App 會先顯示
雲端處理告知並由使用者決定。

## 功能

- **快速聽寫：** 可從 App、選單列、右側 Option 鍵或 Shift-Command-Space
  啟動。從選單列或全域快捷鍵開始時，可把文字送回原本的 App；App 內按鈕則保留
  結果，讓你手動複製。
- **安全貼上：** 會檢查目標 App、Secure Input、權限與剪貼簿所有權。無法安全
  自動貼上時，結果仍會保留，讓你手動複製。
- **語音筆記：** 可把長時間錄音切成可復原區段，也能匯入 M4A、MP3、WAV、AIFF
  與 CAF。
- **結構化 Markdown：** 可預覽上課、會議與一般筆記；重新處理時會保留舊版本。
- **語言與整理控制：** 可分開設定辨識語言與輸出語言，並使用翻譯、逐字、清理、
  潤飾或精簡模式。
- **個人詞彙：** 可建立設定檔專用詞彙與明確的替換規則；建議詞必須確認後才會加入
  啟用中的詞彙。
- **本機歷史與復原：** 可選擇保留快速聽寫歷史、繼續已建立檢查點的工作，並在中斷後
  復原已完成的錄音區段。

## 快速開始

1. 開啟 [Releases](https://github.com/nnnc8/SpeakNote/releases/latest)。只有在頁面有
   發行檔案，而且發行說明清楚交代簽署與公證狀態時才下載。
2. 把 SpeakNote 移到「應用程式」後開啟。
3. 依照初始設定操作。每項權限會分開請求，而且只會在你選擇相關功能時出現。
4. 在「設定 → 服務提供者」選擇 Apple Speech 或 Groq Cloud。Groq 功能需要你自己的
   Groq 憑證，並先確認雲端處理告知。
5. 若要安全地自動貼上，請從選單列或全域快捷鍵開始；App 內按鈕會留下結果供手動
   複製。右側 Option 快捷鍵需要「輸入監控」；自動送出 Command-V 則需要
   「輔助使用」。

## 權限與隱私

| 權限 | SpeakNote 的用途 | 未授權時 |
|---|---|---|
| 麥克風 | 即時聽寫與語音筆記錄音 | 仍可匯入音訊 |
| 輸入監控 | 偵測右側 Option 快捷鍵 | 改用 Shift-Command-Space 或 App／選單列控制 |
| 輔助使用 | 對原本的 App 送出 Command-V | 手動複製結果 |
| 語音辨識 | 選用裝置端 Apple Speech | 改用其他已設定的服務提供者 |

SpeakNote 不含分析或廣告追蹤。固定事件記錄不包含音訊、辨識文字、提示內容、服務回應
或憑證。Groq 憑證存放在 macOS 鑰匙圈；非敏感偏好設定使用 UserDefaults；歷史與語音
筆記檔案保留在 App 容器中，直到你刪除為止。

服務提供者資料流：

- **Apple Speech：** 選定的語言、模型資產、macOS 版本與音訊長度都受支援時，
  辨識會留在這部 Mac 上。
- **Groq Cloud：** 音訊會傳送至 Groq 進行轉錄。若選用雲端清理、翻譯、壓縮或
  結構化筆記處理，文字也會傳送至 Groq。
- **備援：** SpeakNote 不會在沒有告知的情況下跨越本機／雲端界線。預設政策會先
  詢問；僅限本機模式則會阻擋雲端使用。

完整內容請見[隱私權說明](docs/privacy/index.md)與[架構概覽](docs/architecture.md)。

## 相容性

- macOS 14 或更新版本
- 建置目標包含 Apple 晶片與 Intel
- Apple Speech 可用性會受 macOS 版本、語言、已下載模型與音訊長度影響；不支援時
  SpeakNote 會明確顯示，不會自行切換服務提供者
- 目前以直接發行為主。全域快捷鍵與跨 App 貼上仍需用正式簽署版本在真實系統驗證，
  因此 Mac App Store 相容性仍在評估中

## 常見問題

### SpeakNote 可以離線使用嗎？

Apple Speech 通過能力檢查時可在裝置端運作；Groq 功能需要網路連線。

### SpeakNote 會讀取其他 App 裡的文字嗎？

不會。它只記錄原本的 App 身分，把結果寫入剪貼簿，並在安全時送出 Command-V；
不會透過「輔助使用」API 讀取其他 App 的文字。

### 自動貼上失敗時會怎樣？

SpeakNote 會保留辨識結果，供你手動複製。如果無法確認目前剪貼簿仍由 SpeakNote
持有，也不會強行覆寫。

### 語音筆記存放在哪裡？

存放在 SpeakNote 的沙盒容器中。匯入檔案會複製到 App 的工作階段儲存區，因此後續
處理不必依賴原始檔案。

### 現在有完成簽署的版本可以下載嗎？

不能只看原始碼版本判斷。請以 Releases 頁面為準；公開版本應在發行說明中標示簽署
與公證狀態。

## 建置與測試

需求：

- 完整安裝、包含 macOS 26 SDK 或更新版本的 Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
xcodegen generate
xcodebuild -project SpeakNote.xcodeproj -scheme SpeakNote \
  -destination 'platform=macOS' build test
```

自動化測試使用注入的服務與本機 fixture，不會發出真實 Groq 請求。正式發行還需要
Developer ID 簽署、公證與乾淨 Mac 驗證；詳見 [docs/release.md](docs/release.md)。

## 貢獻、支援與授權

- 提交 pull request 前，請先閱讀 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 回報前請先查看 [SUPPORT.md](SUPPORT.md) 所需資訊。
- 使用問題請到 [GitHub Discussions](https://github.com/nnnc8/SpeakNote/discussions)。
- 可重現的錯誤請提交至 [GitHub Issues](https://github.com/nnnc8/SpeakNote/issues)。
- 敏感安全問題請依照 [SECURITY.md](SECURITY.md) 回報。

SpeakNote 採用 [MIT License](LICENSE)。
