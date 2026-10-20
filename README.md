<div align="center">
  <img src="Sources/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="160" height="160" alt="SwiftShot App Icon" />
  <h1>SwiftShot</h1>
  <p><strong>A lightning-fast, ultra-lightweight, 100% native macOS screenshot & annotation tool — with an MCP server so AI coding agents can see your screen.</strong></p>

  <p>
    <a href="https://github.com/luongndcoder/SwiftShot/releases"><img src="https://img.shields.io/badge/Release-1.1.0-blue.svg?style=flat-square" alt="Release" /></a>
    <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0%2B-black.svg?style=flat-square&logo=apple" alt="macOS 14+" /></a>
    <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%20%7C%206.0-orange.svg?style=flat-square&logo=swift" alt="Swift" /></a>
    <a href="#ram-comparison"><img src="https://img.shields.io/badge/RAM-~70MB-brightgreen.svg?style=flat-square" alt="RAM" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="License" /></a>
  </p>
</div>

---

> 🌐 **Language / Ngôn ngữ:** [English](#english) | [Tiếng Việt](#tiếng-việt)

---

<a name="english"></name>
## 🇬🇧 English

### 💡 Why SwiftShot?

[Flameshot](https://github.com/flameshot-org/flameshot) is hands down one of the best screenshot tools ever built. However, running Flameshot on macOS often consumes **over 1.3 GB of RAM** due to its cross-platform Qt6 runtime and background processes, causing sluggishness and frequent security permission popups on modern macOS.

**SwiftShot** is a ground-up, 100% native rewrite for macOS using **Swift**, **ScreenCaptureKit**, **AppKit** and **CoreGraphics**. It delivers the same beloved in-place annotation workflow — plus an **MCP server** no other screenshot tool has — while dropping memory consumption from **1.3 GB down to ~70 MB** (a 17x reduction!).

### ✨ Features

- **🚀 Ultra-Low RAM Footprint**: Idles at ~**70 MB** RSS compared to Flameshot's 1.3 GB.
- **🎯 In-Place HUD Workflow**: No separate preview or pop-up editor window. The toolbar floats right alongside your selection.
- **🖐️ Move Selection Tool**: grab the selection with a hand cursor (🖐 → ✊), like Flameshot.
- **📐 8 Dynamic Resize Handles**: directional resize cursors (↔ ↕ ⇱ ⇲), drag-move, aspect-locked and symmetric resize.
- **📌 Pin to Desktop (`⌘P`)**: pin any screenshot region into an always-on-top, draggable, zoomable floating sticker.
- **🔢 Step Counter Badge (`N`)**: click anywhere to drop auto-incrementing numbered badges (① ② ③...).
- **🎨 Complete Annotation Suite**:
  - ↗️ Arrow (`A`) · 📏 Line (`D`) · 🔲 Rectangle (`R`) · ⬛ Filled Rectangle · ⭕ Ellipse (`C`)
  - ✏️ Pencil (`P`) · 🖍️ Marker (`M`) · 💬 Text (`T`) · 🔢 Counter (`N`)
  - 💧 Gaussian Blur (`B`) · 🏁 Pixelate · 🔄 Invert Colors (`I`)
  - 🎨 8-color quick palette + full **colour picker** + **eyedropper** (`G`) + user colour presets
- **⌨️ Pro Drawing Modifiers** (Flameshot parity):
  - `Ctrl` + drag *line / arrow / marker* → snaps to 0° / 45° / 90°
  - `Ctrl` + drag *rectangle / ellipse* → keeps the aspect ratio
  - `Shift` + drag a handle → resizes the opposite handle symmetrically
  - `Ctrl+Shift` + arrows → resizes symmetrically by 2px
  - `Delete` → removes the selected annotation
- **💾 Flexible Saving**: PNG or JPEG (adjustable quality), `Save As…` (`⇧⌘S`) opens the save panel, optional "copy file path".
- **🖼️ Capture Options**: reuse the last region, copy on double click, configurable dim opacity, optional pixel magnifier with RGB/HEX readout.
- **⚡ Pixel-Perfect Retina Capture**: powered by macOS 14+ `ScreenCaptureKit` at native backing scale.
- **🔒 Stable TCC Permissions**: signed with a persistent developer signature (Apple Development certificate) so the Screen Recording permission is granted **once** and survives rebuilds.
- **🤖 MCP Server for AI coding agents** — see below.

### 📊 RAM Comparison

| Screenshot App | Technology Stack | Idle RAM | Active Capture RAM |
| :--- | :--- | ---: | ---: |
| **Flameshot** | C++ / Qt6 Runtime | **~1,300 MB** | ~1,450 MB |
| **SwiftShot** | **100% Native Swift / AppKit** | **~70 MB** | **~85 MB** |

---

### 🤖 MCP Server — let your AI agent see the screen

This is SwiftShot's exclusive feature: it ships a **Model Context Protocol server**, so AI coding agents (Claude Code, Cursor, Continue, Zed, …) can take screenshots of your Mac and read the pixels directly.

```
AI agent  ──stdio/JSON-RPC──▶  swiftshot-mcp  ──unix socket──▶  SwiftShot.app
                                                                    │
                                                          owns the Screen Recording
                                                                permission
```

**Why this design?** The MCP server never touches the screen itself — it asks the **running SwiftShot app** over a unix socket. The app already holds the Screen Recording permission, so the agent needs **no second TCC grant** and the capture always uses the same code path as the app.

#### Tools

| Tool | Description |
| :--- | :--- |
| `swiftshot_capture` | Takes a screenshot (full display or a region) and returns the image. |
| `swiftshot_displays` | Lists the connected displays with id, name, frame and scale. |
| `swiftshot_status` | App version, bundle id, Screen Recording permission state. |
| `swiftshot_settings` | Reads or updates the preferences. |
| `swiftshot_open_settings` | Opens the preferences window for the user. |

#### Install

```bash
git clone https://github.com/luongndcoder/SwiftShot.git
cd SwiftShot
./install.sh          # build + install the app
./install-mcp.sh      # build + install the MCP server
```

`install-mcp.sh` builds the server and copies it to `~/.local/bin/swiftshot-mcp`.

#### Register with your agent

```bash
# Claude Code
claude mcp add swiftshot -- ~/.local/bin/swiftshot-mcp
```

Or add it to any MCP client configuration:

```json
{
  "mcpServers": {
    "swiftshot": {
      "command": "/Users/you/.local/bin/swiftshot-mcp"
    }
  }
}
```

SwiftShot has to be running — it owns the screen recording permission:

```bash
open -a SwiftShot
```

#### Example

```jsonc
// an agent asking for a screenshot
{
  "name": "swiftshot_capture",
  "arguments": {
    "region": { "x": 0, "y": 0, "width": 1280, "height": 800 },
    "format": "png"
  }
}
```

The region uses **global screen coordinates in points** with the origin in the **bottom-left** corner (the same coordinate system as `NSScreen.frame`).

#### Verify the setup

```bash
python3 Tests/e2e_mcp.py
```

The end-to-end suite speaks the real MCP protocol against the real app and validates the returned PNG bytes, the cropped region sizes, the JPEG encoder, the settings round-trip and the error handling.

---

### 📦 Installation

#### Option 1 — One-Click Build & Install from Source (Recommended)

Requires macOS 14.0+ and Xcode command line tools:

```bash
git clone https://github.com/luongndcoder/SwiftShot.git
cd SwiftShot
./install.sh
```

The script builds the Release binary, codesigns it with your local Apple Development certificate, installs it to `/Applications/SwiftShot.app` and launches it.

#### Option 2 — Build via Xcode

```bash
brew install xcodegen   # one-time
./generate.sh
open SwiftShot.xcodeproj
```

Press **⌘R** to run.

---

### ⚙️ First-Time Setup

1. **Grant Screen Recording Permission**
   - **System Settings** → **Privacy & Security** → **Screen Recording** → toggle **SwiftShot** on.
2. **Override the default macOS `⇧⌘4` shortcut**
   - **System Settings** → **Keyboard** → **Keyboard Shortcuts…** → **Screenshots** → uncheck *Save picture of selected area as a file*.
   - Now `⌘⇧4` instantly triggers SwiftShot.

---

### ⚙️ Preferences

Open **Settings…** from the menu bar icon:

| Setting | Description |
| :--- | :--- |
| **Global Hotkey** | Click **Record** and press the combination you want (⌘ / ⌃ / ⌥ required). |
| **Also copy to clipboard** | Copies the result in addition to the action you picked. |
| **Also auto-save to folder** | Writes a file in addition to the action you picked. |
| **Save folder** | Defaults to `~/Pictures/SwiftShot`. |
| **Format** | PNG (lossless) or JPEG with adjustable quality. |
| **Ask where to save** | Shows the save panel instead of writing to the folder. |
| **Copy file path after saving** | Puts the path of the saved file on the clipboard. |
| **Copy on double click** | A double click inside the selection copies it and finishes. |
| **Reuse last region** | The next capture starts with the last selection rectangle. |
| **Show pixel magnifier** | Shows the loupe with the RGB/HEX value while selecting. |
| **Dim outside selection** | Opacity of the dimmed area (0–80 %). |
| **Default Color / Stroke width** | Applied to new annotations. |
| **Color Presets** | Custom colours added with the `+` button in the capture toolbar. |

> **Copy vs. Save** — the **Copy** button (or `⌘C` / `Enter`) copies to the clipboard, the **Save** button (or `⌘S`) writes a file to the save folder. The two "Also…" toggles give you both at once.

---

### ⌨️ Keyboard Shortcuts

| Keys | Description |
| :--- | :--- |
| `⌘⇧4` | Activate capture |
| `⌘C` / `Enter` | Copy the selection to the clipboard |
| `⌘S` | Save to the save folder (PNG or JPEG) |
| `⌘⇧S` | Save As… (choose the name and format) |
| `⌘P` | Pin the screenshot to the desktop |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌘M` | Move the selection area |
| `Esc` | Cancel the capture |
| `Delete` | Remove the selected annotation |
| `A` `D` `R` `C` `P` `M` `T` `B` `I` `N` | Arrow, Line, Rectangle, Ellipse, Pencil, Marker, Text, Blur, Invert, Counter |
| `G` | Eyedropper (pick a colour from the screen) |
| `S` | Selection tool (pick drawn objects) |
| `←` `↓` `↑` `→` | Nudge the selection by 1px (`Shift` resizes by 1px, `Ctrl+Shift` symmetrically by 2px) |
| `Space` | Toggle the toolbar |
| Mouse wheel | Change the stroke thickness |
| Right click | Colour menu |

---

### 🛠️ Development

```bash
./generate.sh                      # regenerate the Xcode project from project.yml
./install.sh                       # build, sign and install the app
./package.sh 1.1.0                 # build a signed release archive in dist/
./install-mcp.sh                   # build and install the MCP server
python3 Tests/e2e_mcp.py           # end-to-end tests of the MCP server
cd MCP && swift build -c release   # build only the MCP server
```

### 📄 License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for more information.

### 💖 Acknowledgements

- Inspired by the incredible work of the [Flameshot](https://github.com/flameshot-org/flameshot) team.
- App icon artwork crafted with modern Apple Human Interface Guidelines aesthetic.

---

<a name="tiếng-việt"></name>
## 🇻🇳 Tiếng Việt

### 💡 Tại sao lại có SwiftShot?

[Flameshot](https://github.com/flameshot-org/flameshot) là một công cụ chụp ảnh màn hình tuyệt vời. Tuy nhiên trên macOS, Flameshot thường ngốn tới **hơn 1.3 GB RAM** do chạy trên runtime Qt6 cồng kềnh, gây lag máy và thường xuyên bị mất quyền quay màn hình sau mỗi lần khởi động.

**SwiftShot** là ứng dụng viết lại hoàn toàn native 100% cho macOS bằng **Swift**, **ScreenCaptureKit** và **AppKit**. Giữ nguyên trải nghiệm vẽ chú thích in-place của Flameshot — cộng thêm **MCP server** mà không công cụ chụp ảnh nào khác có — trong khi cắt giảm RAM từ **1.3 GB xuống chỉ còn ~70 MB** (nhẹ hơn 17 lần!).

### ✨ Tính năng nổi bật

- **🚀 Siêu nhẹ & Native 100%**: chỉ chiếm ~**70 MB RAM**, không phụ thuộc Electron, không dùng Qt runtime.
- **🎯 Giao diện HUD In-Place**: không mở cửa sổ preview riêng biệt, thanh công cụ nổi ngay sát khung chọn.
- **🖐️ Tool Move Selection**: kéo vùng chọn bằng "bàn tay" (🖐 khi hover, ✊ khi kéo) — giống Flameshot.
- **📐 8 Điểm điều khiển**: có cursor resize hướng (↔ ↕ ⇱ ⇲), kéo di chuyển, giữ tỉ lệ, resize đối xứng.
- **📌 Ghim ảnh lên màn hình (`⌘P`)**: sticker nổi always-on-top, kéo di chuyển, cuộn chuột để zoom.
- **🔢 Đánh số bước tự động (`N`)**: click tới đâu đánh số thứ tự ① ② ③.
- **🎨 Bộ công cụ chú thích đầy đủ**: Mũi tên, Đường thẳng, Chữ nhật, Chữ nhật đặc, Hình tròn, Bút chì, Bút dạ quang, Chữ, Đếm bước, Làm mờ, Pixelate, **Đảo màu** — kèm color picker, **eyedropper** và preset màu tự thêm.
- **⌨️ Modifier chuyên nghiệp**: `Ctrl` kéo → khoá góc 45°, `Ctrl` kéo hình → giữ tỉ lệ, `Shift` kéo handle → resize đối xứng, `Delete` → xoá object.
- **💾 Lưu linh hoạt**: PNG hoặc JPEG (chỉnh quality được), `Save As…` mở hộp thoại, tuỳ chọn copy đường dẫn file.
- **🤖 MCP Server cho AI coding agent** — xem bên dưới.

### 🤖 MCP Server — cho agent AI nhìn thấy màn hình

Đây là tính năng độc quyền của SwiftShot: app đi kèm **MCP server** (Model Context Protocol), nên các AI coding agent (Claude Code, Cursor, Continue, Zed…) có thể tự chụp màn hình Mac và đọc trực tiếp pixel.

```
AI agent  ──stdio/JSON-RPC──▶  swiftshot-mcp  ──unix socket──▶  SwiftShot.app
                                                                    │
                                                          giữ quyền Screen Recording
```

**Vì sao thiết kế kiểu này?** MCP server **không tự chụp màn hình** — nó nhờ chính **app SwiftShot đang chạy** thông qua unix socket. App đã có sẵn quyền Screen Recording nên agent **không cần cấp quyền TCC lần thứ hai**, và ảnh luôn được chụp đúng bằng code path của app.

**5 tool**: `swiftshot_capture` · `swiftshot_displays` · `swiftshot_status` · `swiftshot_settings` · `swiftshot_open_settings`

**Cài đặt:**

```bash
./install.sh          # build + cài app
./install-mcp.sh      # build + cài MCP server vào ~/.local/bin

# đăng ký với Claude Code
claude mcp add swiftshot -- ~/.local/bin/swiftshot-mcp

# app phải đang chạy
open -a SwiftShot
```

**Kiểm tra:**

```bash
python3 Tests/e2e_mcp.py
```

Bộ test E2E nói đúng giao thức MCP thật với app thật và kiểm tra byte PNG trả về, kích thước vùng crop, encoder JPEG, round-trip settings và xử lý lỗi.

### 📄 License

MIT — xem [LICENSE](LICENSE).
