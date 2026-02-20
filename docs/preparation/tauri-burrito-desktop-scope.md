# Implementation Scope: Tauri + Burrito Desktop Distribution for Synaptic Assistant

## Executive Summary

This document scopes the work required to wrap the Synaptic Assistant Phoenix/LiveView application as a standalone desktop application distributed via Tauri (native window/WebView) + Burrito (Elixir binary packaging). The architecture uses a **sidecar model**: Tauri provides the native window shell with OS-native WebView, while Burrito packages the entire Phoenix backend (including ERTS) into a self-contained binary that runs as a child process. The result is a single downloadable installer per platform (macOS, Windows, Linux) with auto-update, code signing, and no end-user runtime dependencies.

**Estimated complexity**: High. This touches build infrastructure, CI/CD, platform-specific tooling, database strategy, and code signing across three platforms. The core application code changes are modest, but the surrounding infrastructure is substantial.

**Key risk**: ex_tauri (the Elixir-Tauri bridge library) is a proof-of-concept with 12 commits, 3 contributors, and is not published on Hex. The alternative is manual Tauri+Burrito integration following the MrPopov pattern, which is more work but more maintainable.

---

## 1. Architecture

### 1.1 Component Model

```
+----------------------------------------------------------+
|                    Tauri Shell (Rust)                     |
|  +----------------------------------------------------+  |
|  |              OS-Native WebView                      |  |
|  |  (WebKit on macOS/Linux, WebView2/Edge on Windows)  |  |
|  |                                                     |  |
|  |  Connects to: http://127.0.0.1:{dynamic_port}      |  |
|  +----------------------------------------------------+  |
|                                                          |
|  Sidecar Process: assistant-backend-{target-triple}      |
|  (Burrito-wrapped Phoenix release)                       |
|                                                          |
|  Lifecycle:                                              |
|  1. Tauri launches sidecar binary                        |
|  2. Sidecar starts Phoenix on dynamic port               |
|  3. Tauri polls until HTTP responds (up to 60s)          |
|  4. WebView opens to localhost:{port}                    |
|  5. On window close, Tauri sends shutdown signal         |
+----------------------------------------------------------+
                          |
              +-----------+-----------+
              |                       |
     +--------v--------+    +--------v--------+
     |   PostgreSQL     |    |   Local SQLite   |
     |   (remote DB)    |    |   (offline mode) |
     +------------------+    +------------------+
```

### 1.2 How It Works

1. **Burrito** wraps a `mix release` of the Phoenix app into a platform-specific binary. The binary embeds ERTS (Erlang Runtime System), all compiled BEAM files, NIFs, and static assets. On first run it extracts to `~/.synaptic-assistant/` (or platform equivalent). No Erlang/Elixir installation required on end-user machines.

2. **Tauri** provides the native application wrapper: window management, system tray, menus, and the WebView that renders the Phoenix LiveView UI. Tauri is written in Rust and compiles to a small native binary (~2-3 MB).

3. **Communication**: HTTP for UI rendering (WebView loads LiveView pages). Lifecycle management via either:
   - Unix domain socket heartbeat (ex_tauri approach)
   - Stdout/stdin IPC (Tauri sidecar native approach)
   - Process signal handling

4. **Auto-update**: Tauri's built-in updater plugin checks a configured endpoint (GitHub Releases or custom server) for new versions, downloads, verifies signature, and applies.

### 1.3 Key Architectural Decision: Database Strategy

**Current state**: Synaptic Assistant uses PostgreSQL (via Postgrex + Ecto). It depends on Oban (Postgres-backed job queue), Cloak.Ecto (encrypted fields), and Ecto migrations.

**Options**:

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| A) Keep PostgreSQL | Bundle connects to remote/local PG | No code changes, full feature parity | Users must have PG running (or use hosted PG) |
| B) Dual adapter | SQLite for desktop, PG for server | Offline-capable, zero-dep install | Significant effort: Oban alternative needed, schema compat testing |
| C) Embedded PG | Bundle PostgreSQL binary | Full compat, no code changes | Large binary (~100MB+), complex lifecycle management |
| D) Remote-only | Desktop connects to cloud PG | Simple, no data layer changes | Requires internet, needs auth/multi-tenancy |

**Recommendation**: Option A (Keep PostgreSQL) for initial release. Users either:
- Run a local PostgreSQL instance, or
- Connect to a hosted PostgreSQL (Neon, Supabase, Railway, etc.)

The desktop app provides a first-run setup screen for database connection configuration. This avoids the Oban+Cloak SQLite compatibility problem entirely.

Option B (dual adapter) could be a future enhancement but requires replacing Oban with an SQLite-compatible job queue (e.g., Oban Lite, or custom GenServer-based queue).

---

## 2. Codebase Changes Required

### 2.1 New Files/Directories

```
src-tauri/                          # Tauri application root
  src/
    main.rs                         # Tauri entry point, sidecar lifecycle
    lib.rs                          # Plugin setup (updater, shell, etc.)
  Cargo.toml                        # Rust dependencies
  tauri.conf.json                   # Window config, sidecar, updater, bundle
  capabilities/
    default.json                    # Permissions (shell:allow-execute)
  icons/                            # App icons for all platforms
  binaries/                         # Symlinks to Burrito output

assets-tauri/                       # (Optional) Tauri-specific frontend assets
  index.html                        # Loading/splash screen shown while Phoenix boots

scripts/
  build-sidecar.sh                  # Builds Burrito release + creates symlinks
  build-desktop.sh                  # Full pipeline: sidecar + Tauri build
```

### 2.2 Modified Files

| File | Change | Purpose |
|------|--------|---------|
| `mix.exs` | Add `:burrito` dependency, add `desktop` release target with Burrito steps | Enable binary packaging |
| `config/runtime.exs` | Add desktop-mode detection (BURRITO_TARGET), dynamic port, data directory | Runtime behavior for desktop context |
| `lib/assistant/application.ex` | Conditional children based on desktop mode (skip DNSCluster, adjust repo config) | Graceful desktop startup |
| `lib/assistant_web/endpoint.ex` | Dynamic port binding, CORS/origin adjustments for localhost | Desktop WebView compatibility |
| `.gitignore` | Add `src-tauri/target/`, `burrito_out/` | Ignore build artifacts |

### 2.3 Detailed Change Descriptions

#### mix.exs Changes

```elixir
# In deps:
{:burrito, "~> 1.5"}

# In project():
releases: [
  assistant: [                        # Standard server release (unchanged)
    steps: [:assemble]
  ],
  assistant_desktop: [                # Desktop release with Burrito
    steps: [:assemble, &Burrito.wrap/1],
    burrito: [
      targets: [
        macos_aarch64: [os: :darwin, cpu: :aarch64],
        macos_x86_64:  [os: :darwin, cpu: :x86_64],
        linux_x86_64:  [os: :linux,  cpu: :x86_64],
        linux_aarch64: [os: :linux,  cpu: :aarch64],
        windows_x86_64: [os: :windows, cpu: :x86_64]
      ]
    ]
  ]
]
```

#### config/runtime.exs Additions

```elixir
# Desktop mode detection
desktop_mode? = System.get_env("BURRITO_TARGET") != nil

if desktop_mode? do
  # Dynamic port (let OS assign)
  config :assistant, AssistantWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 0],
    server: true,
    check_origin: false

  # Data directory in user home
  data_dir = Path.join(System.user_home!(), ".synaptic-assistant")
  File.mkdir_p!(data_dir)

  # Write port file for Tauri to read
  config :assistant, :desktop_data_dir, data_dir
  config :assistant, :desktop_mode, true
end
```

#### Tauri Main (src-tauri/src/main.rs) -- Conceptual

```rust
// Pseudocode for sidecar lifecycle
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            // Spawn Phoenix sidecar
            let sidecar = app.shell().sidecar("assistant-backend")?;
            let (mut rx, child) = sidecar.spawn()?;

            // Poll until Phoenix responds
            // Read port from file or stdout
            // Navigate WebView to http://127.0.0.1:{port}
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

### 2.4 NIF Considerations

Synaptic Assistant uses these NIFs that Burrito must handle:

| Dependency | NIF? | Cross-compile Notes |
|------------|------|---------------------|
| bcrypt_elixir | Yes (C NIF) | Burrito recompiles via Zig |
| postgrex | No (pure Erlang) | No issues |
| jason | Optional NIF (jason_native) | Pure Elixir fallback available |
| cloak_ecto | No | No issues |
| earmark | No | No issues |
| muontrap | Yes (C NIF) | Burrito recompiles via Zig |

The bcrypt_elixir and muontrap NIFs require Burrito's NIF cross-compilation pipeline. This is supported but may need per-target `nif_cflags` tuning.

---

## 3. CI/CD Multi-Platform Build Pipeline

### 3.1 GitHub Actions Workflow

The build pipeline has two stages: (1) build Burrito sidecar binaries, (2) build Tauri installers.

```yaml
name: Desktop Release

on:
  push:
    tags: ['v*']
  workflow_dispatch:

env:
  TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
  TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}

jobs:
  build-sidecar:
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: macos-latest
            target: macos_aarch64
            triple: aarch64-apple-darwin
          - os: macos-13              # Intel Mac runner
            target: macos_x86_64
            triple: x86_64-apple-darwin
          - os: ubuntu-22.04
            target: linux_x86_64
            triple: x86_64-unknown-linux-gnu
          - os: ubuntu-22.04-arm
            target: linux_aarch64
            triple: aarch64-unknown-linux-gnu
          - os: windows-latest
            target: windows_x86_64
            triple: x86_64-pc-windows-msvc

    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Install Erlang/Elixir
        uses: erlef/setup-beam@v1
        with:
          otp-version: '27.x'
          elixir-version: '1.18.x'
      - name: Install Zig
        uses: mlugg/setup-zig@v1
        with:
          version: 0.15.2
      - name: Build sidecar
        env:
          MIX_ENV: prod
          BURRITO_TARGET: ${{ matrix.target }}
        run: |
          mix deps.get --only prod
          mix assets.deploy
          mix release assistant_desktop
      - name: Rename binary for Tauri sidecar convention
        run: |
          # Renames burrito_out/assistant_desktop to
          # assistant-backend-{triple}[.exe]
      - uses: actions/upload-artifact@v4
        with:
          name: sidecar-${{ matrix.target }}
          path: src-tauri/binaries/

  build-tauri:
    needs: build-sidecar
    permissions:
      contents: write
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: macos-latest
            args: '--target aarch64-apple-darwin'
          - platform: macos-13
            args: '--target x86_64-apple-darwin'
          - platform: ubuntu-22.04
            args: ''
          - platform: ubuntu-22.04-arm
            args: ''
          - platform: windows-latest
            args: ''

    runs-on: ${{ matrix.platform }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          pattern: sidecar-*
          path: src-tauri/binaries/
          merge-multiple: true
      - name: Install Rust stable
        uses: dtolnay/rust-toolchain@stable
      - uses: swatinem/rust-cache@v2
        with:
          workspaces: './src-tauri -> target'
      - name: Install Linux dependencies
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y libwebkit2gtk-4.1-dev \
            libappindicator3-dev librsvg2-dev patchelf
      - uses: tauri-apps/tauri-action@v0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          # macOS signing
          APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
          APPLE_API_ISSUER: ${{ secrets.APPLE_API_ISSUER }}
          APPLE_API_KEY: ${{ secrets.APPLE_API_KEY }}
          APPLE_API_KEY_PATH: ${{ secrets.APPLE_API_KEY_PATH }}
          # Windows signing
          WINDOWS_CERTIFICATE: ${{ secrets.WINDOWS_CERTIFICATE }}
          WINDOWS_CERTIFICATE_PASSWORD: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}
        with:
          tagName: v__VERSION__
          releaseName: 'Synaptic Assistant v__VERSION__'
          releaseBody: 'Desktop release. See assets for platform-specific installers.'
          releaseDraft: true
          prerelease: false
          includeUpdaterJson: true
          args: ${{ matrix.args }}
```

### 3.2 Build Matrix Summary

| Platform | Runner | Sidecar Target | Installer Format |
|----------|--------|---------------|------------------|
| macOS (Apple Silicon) | macos-latest | darwin/aarch64 | .dmg, .app |
| macOS (Intel) | macos-13 | darwin/x86_64 | .dmg, .app |
| Linux (x64) | ubuntu-22.04 | linux/x86_64 | .AppImage, .deb |
| Linux (ARM64) | ubuntu-22.04-arm | linux/aarch64 | .AppImage, .deb |
| Windows (x64) | windows-latest | windows/x86_64 | .msi, .exe (NSIS) |

### 3.3 Build Time Estimates

| Stage | Estimated Time |
|-------|---------------|
| Erlang/Elixir setup | 2-3 min |
| Mix deps.get + compile | 3-5 min |
| Burrito sidecar build | 5-10 min |
| Tauri build | 3-5 min |
| Code signing + notarization | 2-5 min |
| **Total per platform** | **15-28 min** |
| **Total (5 platforms parallel)** | **~30 min** |

---

## 4. Code Signing

### 4.1 macOS

**Requirements**:
- Apple Developer Program membership ($99/year)
- "Developer ID Application" certificate (for distribution outside App Store)
- App-specific password for notarization

**Tauri Configuration** (`tauri.conf.json`):
```json
{
  "bundle": {
    "macOS": {
      "signingIdentity": "Developer ID Application: Your Name (TEAM_ID)",
      "hardenedRuntime": true,
      "minimumSystemVersion": "10.15"
    }
  }
}
```

**CI/CD Secrets Required**:
| Secret | Description |
|--------|-------------|
| `APPLE_CERTIFICATE` | Base64-encoded .p12 certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Certificate export password |
| `APPLE_SIGNING_IDENTITY` | Certificate identity string |
| `APPLE_API_ISSUER` | App Store Connect API issuer ID |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_KEY_PATH` | Path to .p8 private key file |

**Notarization**: Tauri handles notarization automatically during build when credentials are configured. Apple notarization ensures the app passes Gatekeeper on all macOS versions.

**Cost**: $99/year Apple Developer Program.

### 4.2 Windows

**Requirements**:
- Code signing certificate from an approved CA
- For immediate SmartScreen trust: EV (Extended Validation) certificate (~$200-400/year)
- For budget option: OV (Organization Validation) certificate (~$70-200/year) -- but SmartScreen warnings persist until reputation builds

**Tauri Configuration** (`tauri.conf.json`):
```json
{
  "bundle": {
    "windows": {
      "certificateThumbprint": "...",
      "digestAlgorithm": "sha256",
      "timestampUrl": "http://timestamp.comodoca.com"
    }
  }
}
```

**CI/CD Secrets Required**:
| Secret | Description |
|--------|-------------|
| `WINDOWS_CERTIFICATE` | Base64-encoded .pfx file |
| `WINDOWS_CERTIFICATE_PASSWORD` | PFX export password |

**Alternative**: Azure Key Vault or Azure Code Signing for cloud-managed certificates.

**Cost**: $70-400/year depending on certificate type.

### 4.3 Linux

Linux does not require code signing for distribution. However, for enhanced trust:
- GPG-sign releases
- Publish to package repositories (AUR, PPA, Flatpak) which have their own verification

### 4.4 Tauri Update Signing

Separate from OS code signing, Tauri requires its own signature keypair for verifying updates:

```bash
npx tauri signer generate -w ~/.tauri/synaptic-assistant.key
```

This produces a public key (goes in `tauri.conf.json`) and private key (goes in CI/CD secrets as `TAURI_SIGNING_PRIVATE_KEY`).

---

## 5. Auto-Update

### 5.1 Tauri Updater Plugin

Tauri v2 includes a built-in updater plugin that:
1. Checks configured endpoints for update manifests
2. Downloads platform-specific installer
3. Verifies Tauri signature (mandatory, cannot be disabled)
4. Applies update (restart required)

**Configuration** (`tauri.conf.json`):
```json
{
  "bundle": {
    "createUpdaterArtifacts": true
  },
  "plugins": {
    "updater": {
      "pubkey": "CONTENT_OF_PUBLIC_KEY",
      "endpoints": [
        "https://github.com/OWNER/REPO/releases/latest/download/latest.json"
      ]
    }
  }
}
```

### 5.2 Update Flow

1. On app launch (or periodic check), Tauri fetches `latest.json` from endpoint
2. `latest.json` contains version, platform-specific URLs, and signatures
3. If newer version available, app can prompt user or auto-download
4. Downloaded installer is verified against public key
5. App restarts with new version

### 5.3 Update Manifest (latest.json)

Generated automatically by `tauri-action` with `includeUpdaterJson: true`:

```json
{
  "version": "1.2.0",
  "notes": "Bug fixes and performance improvements",
  "pub_date": "2026-02-20T12:00:00Z",
  "platforms": {
    "darwin-aarch64": {
      "signature": "...",
      "url": "https://github.com/.../Synaptic-Assistant_1.2.0_aarch64.dmg.tar.gz"
    },
    "linux-x86_64": {
      "signature": "...",
      "url": "https://github.com/.../Synaptic-Assistant_1.2.0_amd64.AppImage.tar.gz"
    },
    "windows-x86_64": {
      "signature": "...",
      "url": "https://github.com/.../Synaptic-Assistant_1.2.0_x64-setup.nsis.zip"
    }
  }
}
```

### 5.4 Update Channels (Optional Enhancement)

Tauri supports dynamic endpoint configuration at runtime, enabling:
- `stable` channel (default)
- `beta` channel (opt-in via settings)
- `nightly` channel (for developers)

---

## 6. Packaging Per Platform

### 6.1 macOS

| Format | Description | Use Case |
|--------|-------------|----------|
| `.dmg` | Disk image with drag-to-install | Primary distribution format |
| `.app` | Application bundle (inside .dmg) | What users actually run |

**Binary size estimate**: ~15-25 MB (Tauri ~3 MB + Burrito sidecar ~12-20 MB)

### 6.2 Windows

| Format | Description | Use Case |
|--------|-------------|----------|
| `.msi` | Windows Installer package | Enterprise/IT-managed deployment |
| `.exe` (NSIS) | Self-extracting installer | Direct download from website |

**Binary size estimate**: ~15-25 MB

### 6.3 Linux

| Format | Description | Use Case |
|--------|-------------|----------|
| `.AppImage` | Portable single-file executable | Universal, no install required |
| `.deb` | Debian/Ubuntu package | apt-based distros |

**Binary size estimate**: ~15-25 MB

---

## 7. Package Manager Distribution

For an open source project aiming for wide distribution, publishing to platform-specific package managers dramatically improves discoverability and install friction. Here is the path for each.

### 7.1 macOS: Homebrew

**Option A: Homebrew Tap (Recommended for start)**

Create a dedicated repository `your-org/homebrew-synaptic-assistant` containing a Cask definition. Users install with:

```bash
brew tap your-org/synaptic-assistant
brew install --cask synaptic-assistant
```

The Cask file points to your GitHub Release `.dmg` asset:

```ruby
cask "synaptic-assistant" do
  version "1.0.0"
  sha256 "SHA256_OF_DMG"

  url "https://github.com/OWNER/REPO/releases/download/v#{version}/Synaptic-Assistant_#{version}_aarch64.dmg"
  name "Synaptic Assistant"
  desc "AI-powered assistant desktop application"
  homepage "https://github.com/OWNER/REPO"

  app "Synaptic Assistant.app"

  zap trash: [
    "~/.synaptic-assistant",
    "~/Library/Application Support/Synaptic Assistant",
  ]
end
```

**Maintenance**: Update the Cask SHA and version on each release. Can be automated with a GitHub Action that pushes to the tap repo after release.

**Option B: Homebrew Core Cask (Future)**

Requires: notable user base, active maintenance, 30+ GitHub stars. Submit PR to `Homebrew/homebrew-cask`. Benefits: users install with just `brew install --cask synaptic-assistant` (no tap needed). Approval process involves review by Homebrew maintainers.

### 7.2 Windows: winget

**Submission process**:

1. Create a manifest YAML file with app metadata, installer URL, and SHA256
2. Submit a PR to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs)
3. Microsoft reviews and merges
4. Users install with: `winget install SynapticAssistant`

**Requirements**: Signed installer (.exe or .msi), stable release URL, manifest conforming to winget schema. Code signing is effectively required (unsigned apps are rejected or heavily penalized).

**Automation**: [winget-releaser](https://github.com/vedantmgoyal9/winget-releaser) GitHub Action can auto-submit manifests on new releases.

### 7.3 Linux: Multiple Channels

| Channel | Effort | Reach | Notes |
|---------|--------|-------|-------|
| **AppImage** (GitHub Releases) | Zero (Tauri produces this) | Universal | Users download from releases page |
| **.deb** (GitHub Releases) | Zero (Tauri produces this) | Debian/Ubuntu | Users download from releases page |
| **AUR** (Arch User Repository) | Low | Arch Linux | Create PKGBUILD that downloads from GitHub Releases |
| **Flatpak** (Flathub) | Medium | Universal | Requires Flatpak manifest, Flathub review process |
| **Snap** (Snapcraft) | Medium | Ubuntu | Requires snapcraft.yaml, Snap Store account |
| **PPA** (Personal Package Archive) | Medium | Ubuntu/Debian | Requires Launchpad account, signing key |
| **.rpm** (COPR) | Medium | Fedora/RHEL | Requires COPR account, spec file |

**Recommended priority**: AppImage + .deb (free from Tauri) first, then AUR (low effort, active community), then Flatpak (wide reach).

**AUR PKGBUILD example**:

```bash
pkgname=synaptic-assistant-bin
pkgver=1.0.0
pkgrel=1
pkgdesc="AI-powered assistant desktop application"
arch=('x86_64')
url="https://github.com/OWNER/REPO"
license=('MIT')
depends=('webkit2gtk-4.1' 'libappindicator-gtk3')
source=("${url}/releases/download/v${pkgver}/synaptic-assistant_${pkgver}_amd64.deb")
sha256sums=('SHA256_HASH')

package() {
  bsdtar -xf data.tar.* -C "$pkgdir/"
}
```

---

## 8. Rust Knowledge Requirements

A common concern: "Does the team need to learn Rust?"

### What You Actually Need to Know

| Area | Rust Knowledge Required | Notes |
|------|------------------------|-------|
| Initial Tauri setup | None | `npm create tauri-app` scaffolds everything |
| `tauri.conf.json` config | None | JSON configuration, no Rust |
| Basic sidecar lifecycle | Minimal (~50 lines) | Copy/adapt from examples. The main.rs is boilerplate |
| Custom window behavior | Low-Medium | Only if you need native menus, system tray, custom events |
| Tauri plugins | None | Install via Cargo.toml, configure via JSON |
| Debugging build issues | Low | Reading Cargo error messages, basic Rust toolchain knowledge |
| Custom IPC commands | Medium | If you need Rust-to-Elixir communication beyond HTTP |

### Realistic Assessment

For this project, the Rust code in `src-tauri/src/main.rs` is approximately **50-100 lines** of mostly boilerplate:

1. Initialize Tauri with plugins (updater, shell)
2. Spawn sidecar process
3. Wait for Phoenix to become ready
4. Open WebView to localhost URL
5. Handle window close (clean shutdown)

This is copy-paste-adapt work from Tauri's official examples. No deep Rust expertise is needed. The Tauri community has extensive examples and the compile-time error messages in Rust are generally helpful.

### Where Rust Knowledge Helps (Optional)

- **Custom native menus**: If you want macOS-style native menus beyond what LiveView provides
- **System tray**: Right-click menu on the system tray icon
- **Custom IPC**: Sending structured data between Rust and the WebView (unlikely needed since Phoenix handles everything via LiveView)
- **Performance-critical native code**: File system watchers, OS notifications (Tauri plugins exist for most of these)

### Team Recommendation

One team member should have basic familiarity with:
- `cargo build` and `cargo tauri dev` commands
- Reading `Cargo.toml` (dependency management, similar to mix.exs)
- Basic Rust syntax (enough to modify the main.rs setup code)

This can be learned in a few hours. Deep Rust expertise is not required.

---

## 9. Dependency Inventory

### 9.1 Build-Time Dependencies

| Dependency | Version | Purpose | Notes |
|------------|---------|---------|-------|
| Erlang/OTP | >= 25.3 | ERTS for Burrito | Must match Burrito precompiled ERTS |
| Elixir | >= 1.18 | Current project requirement | |
| Rust (stable) | Latest | Tauri compilation | |
| Zig | 0.15.2 | Burrito NIF cross-compilation | Must be exact version |
| Node.js | LTS | Tauri CLI (if using npm) | Or use cargo directly |
| cargo-tauri | v2.x | Tauri build CLI | |

### 9.2 Runtime Dependencies (End-User)

| Platform | Required | Notes |
|----------|----------|-------|
| macOS | None | Self-contained |
| Windows | WebView2 (Edge) runtime | Pre-installed on Windows 10/11. Tauri auto-installs if missing |
| Linux | WebKitGTK 4.1, libappindicator3 | Most modern distros have these. AppImage may bundle them |

### 9.3 Elixir Dependencies Added

| Package | Version | Purpose |
|---------|---------|---------|
| burrito | ~> 1.5 | Binary packaging |

### 9.4 Rust Dependencies (in src-tauri/Cargo.toml)

| Crate | Purpose |
|-------|---------|
| tauri | Core framework |
| tauri-plugin-shell | Sidecar management |
| tauri-plugin-updater | Auto-update |

---

## 10. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| NIF cross-compilation failures (bcrypt, muontrap) | Medium | High | Test early on all platforms. May need per-target nif_cflags |
| Burrito breaking changes | Low | Medium | Pin version, test in CI before upgrading |
| macOS Gatekeeper rejection | Low | High | Proper code signing + notarization |
| Windows SmartScreen warnings (OV cert) | High | Medium | Budget for EV cert, or accept initial warnings |
| Large binary size | Medium | Low | Monitor; Burrito+Tauri typically ~15-25 MB |
| ex_tauri abandoned/immature | High | Medium | Do NOT depend on ex_tauri. Build custom Tauri integration |
| PostgreSQL requirement for end users | Medium | High | First-run setup wizard; consider hosted DB option |
| Platform-specific LiveView rendering bugs | Medium | Medium | Test WebView rendering on all platforms |
| Zig version conflicts | Low | Medium | Pin in CI, document in CONTRIBUTING.md |
| Oban incompatible with SQLite | N/A (deferred) | N/A | Only relevant if pursuing dual-adapter option |

---

## 11. Known Gotchas

These are specific pain points and surprises discovered during research that are worth calling out explicitly.

### 11.1 Burrito Binary Naming for Tauri Sidecar

Tauri expects sidecar binaries to follow a strict naming convention: `{name}-{target-triple}` where the target triple is like `x86_64-apple-darwin` or `x86_64-pc-windows-msvc.exe`. Burrito outputs binaries with its own naming. You need a script that renames/symlinks Burrito output to match Tauri's expected names. This must run between the Burrito build step and the Tauri build step in CI.

### 11.2 First-Run Extraction Delay

Burrito binaries are self-extracting archives. On **first launch**, the payload (~15-20 MB) must be extracted to disk (to `~/.synaptic-assistant/` or platform equivalent). This adds a noticeable 3-10 second delay on first launch only. Subsequent launches use the cached extraction. The Tauri window should show a loading/splash screen during this time to avoid the appearance of a broken app.

### 11.3 Zig Version Pinning is Critical

Burrito depends on Zig for cross-compilation and NIF recompilation. The required Zig version (currently 0.15.2) must be exact. Zig has frequent breaking changes between versions. In CI, always pin with `mlugg/setup-zig@v1` and a specific version. Locally, use ZVM (Zig Version Manager) rather than system package managers.

### 11.4 Windows WebView2 Runtime

Tauri on Windows requires WebView2 (Edge Chromium) runtime. It is pre-installed on Windows 10 version 1803+ and Windows 11. For older Windows versions, Tauri's NSIS installer can auto-download and install the WebView2 runtime. However, enterprise environments with restricted install policies may block this. Document this as a system requirement.

### 11.5 macOS Notarization Requires Paid Developer Account

A free Apple Developer account allows code signing but NOT notarization. Without notarization, macOS Gatekeeper will show "app cannot be opened because the developer cannot be verified" -- users can bypass this but it is a poor experience. The $99/year Apple Developer Program is effectively required for macOS distribution.

### 11.6 Dynamic Port Discovery Between Tauri and Phoenix

Since Phoenix runs on a dynamic port (port 0), Tauri needs to discover which port was assigned. Two approaches:

1. **File-based**: Phoenix writes port to a known file path (e.g., `~/.synaptic-assistant/port`), Tauri polls until it appears
2. **Stdout-based**: Phoenix prints port to stdout, Tauri reads from sidecar stdout

The MrPopov pattern uses approach 1. Both work, but stdout-based is slightly more elegant. Either way, the Tauri startup logic must include a polling loop (up to ~60 seconds timeout) before navigating the WebView.

### 11.7 check_origin Must Be Disabled

Phoenix's default `check_origin` security check rejects WebSocket connections from origins that don't match the configured host. Since Tauri's WebView connects from a `tauri://` origin (not `http://localhost`), you must set `check_origin: false` in the endpoint config for desktop mode. This is safe because the endpoint only binds to `127.0.0.1` and is protected by `Desktop.Auth`-style restrictions.

### 11.8 Static Asset Serving in Desktop Mode

The `cache_static_manifest` configuration should be removed/disabled in desktop mode. Desktop apps don't need HTTP cache headers for static assets since the WebView loads directly from localhost. Leaving it enabled can cause issues with assets not being found if the manifest doesn't exist in the Burrito release.

### 11.9 Postgrex Does Not Have Native Dependencies

Good news: Postgrex (the PostgreSQL driver) is pure Erlang/Elixir with no NIFs. This means keeping PostgreSQL as the database does NOT add cross-compilation complexity. The NIFs to worry about are bcrypt_elixir and muontrap.

### 11.10 Burrito Maintenance Commands

Burrito automatically adds maintenance subcommands to the binary (`maintenance uninstall`, `maintenance directory`, `maintenance meta`). These are helpful for debugging but may confuse end users. In a Tauri sidecar context, users never interact with the binary directly, so this is a non-issue.

### 11.11 macOS DMG Building Requires Finder Permissions

When building macOS DMGs locally (not in CI), AppleScript automation requires explicit Finder permissions in System Preferences > Security & Privacy > Privacy > Automation. Without this, the DMG creation fails with error code -1743. In CI (GitHub Actions runners), this permission is pre-granted.

---

## 12. Implementation Phases

### Phase 1: Proof of Concept (1 platform) -- Estimated: 3-5 days of specialist work

1. Add Burrito dependency and desktop release config to mix.exs
2. Add desktop-mode detection in runtime.exs
3. Build Burrito binary for current platform (macOS ARM64)
4. Create minimal Tauri app (src-tauri/) with sidecar config
5. Implement sidecar lifecycle (spawn, poll, connect, shutdown)
6. Verify LiveView renders correctly in Tauri WebView
7. Test: app launches, LiveView works, graceful shutdown

**Success criteria**: Double-click app icon, Phoenix boots, LiveView renders in native window, close window shuts down cleanly.

### Phase 2: Multi-Platform Builds -- Estimated: 3-5 days

1. Add all Burrito targets (macOS x86_64, Linux x64/arm64, Windows x64)
2. Set up GitHub Actions for sidecar builds on all platforms
3. Set up GitHub Actions for Tauri builds on all platforms
4. Test NIF cross-compilation (bcrypt_elixir, muontrap)
5. Verify installer formats (.dmg, .msi/.exe, .AppImage/.deb)

**Success criteria**: CI produces working installers for all 5 platform targets.

### Phase 3: Code Signing & Notarization -- Estimated: 2-3 days

1. Obtain Apple Developer ID Application certificate
2. Obtain Windows code signing certificate (OV or EV)
3. Configure Tauri code signing in tauri.conf.json
4. Add all signing secrets to GitHub Actions
5. Verify signed builds pass Gatekeeper (macOS) and SmartScreen (Windows)

**Success criteria**: Signed installers install without security warnings on macOS. Windows either passes SmartScreen (EV) or shows minimal warning (OV).

### Phase 4: Auto-Update -- Estimated: 2-3 days

1. Generate Tauri signer keypair
2. Configure updater plugin in tauri.conf.json
3. Configure GitHub Actions to produce latest.json with each release
4. Implement update check on app launch
5. Test full update cycle: install v1 -> release v2 -> app auto-updates

**Success criteria**: Running v1 detects v2 release, downloads, verifies, installs, restarts.

### Phase 5: First-Run Experience -- Estimated: 2-3 days

1. Add first-run setup screen (database connection configuration)
2. Add loading/splash screen while Phoenix boots
3. Add system tray icon with quit option
4. Polish window title, icons, menu bar
5. Add "About" dialog with version info

**Success criteria**: New user can download, install, configure database, and start using the app.

---

## 13. Open Questions for Stakeholder Decision

1. **Database strategy**: Keep PostgreSQL (Option A -- recommended for v1) or invest in SQLite dual-adapter (Option B -- significant additional scope)?

2. **ex_tauri vs. manual integration**: Use the PoC library (faster start, fragile) or build custom Tauri integration (more work, more control)? Recommendation: manual integration following MrPopov pattern.

3. **Windows certificate type**: OV ($70-200/yr, SmartScreen warnings initially) or EV ($200-400/yr, immediate trust)?

4. **Update channel strategy**: Single stable channel, or also support beta/nightly from the start?

5. **Mobile support**: Tauri v2 has experimental mobile support. Scope this now or defer?

6. **Universal macOS binary**: Ship separate Intel and ARM binaries, or create a universal binary (larger but simpler for users)?

---

## 14. Cost Summary

| Item | Cost | Frequency |
|------|------|-----------|
| Apple Developer Program | $99 | Annual |
| Windows code signing (OV) | $70-200 | Annual |
| Windows code signing (EV) | $200-400 | Annual |
| GitHub Actions (runners) | Free for open source | Per build |
| **Total (minimum)** | **~$170/year** | |
| **Total (with EV)** | **~$300-500/year** | |

---

## 15. References

### Primary Sources (Official Documentation)
- [Tauri v2 Documentation](https://v2.tauri.app/)
- [Tauri Sidecar Guide](https://v2.tauri.app/develop/sidecar/)
- [Tauri Updater Plugin](https://v2.tauri.app/plugin/updater/)
- [Tauri macOS Code Signing](https://v2.tauri.app/distribute/sign/macos/)
- [Tauri Windows Code Signing](https://v2.tauri.app/distribute/sign/windows/)
- [Tauri GitHub Actions](https://v2.tauri.app/distribute/pipelines/github/)
- [Burrito GitHub Repository](https://github.com/burrito-elixir/burrito)
- [Burrito on Hex.pm](https://hex.pm/packages/burrito) (v1.5.0, Nov 2025)

### Integration Examples
- [ex_tauri](https://github.com/filipecabaco/ex_tauri) -- Elixir-Tauri bridge (PoC, 93 stars)
- [Taulixir](https://github.com/grouvie/taulixir) -- Tauri + Elixir sample with Erlang RPC
- [MrPopov: Elixir LiveView Single Binary](https://mrpopov.com/posts/elixir-liveview-single-binary/) -- Practical walkthrough
- [CrabNebula: Building Apps with Tauri and Elixir](https://crabnebula.dev/blog/tauri-elixir-phoenix/)

### Tauri Build Infrastructure
- [tauri-apps/tauri-action](https://github.com/tauri-apps/tauri-action) -- GitHub Actions for Tauri
- [CrabNebula Cloud: Auto Updates](https://docs.crabnebula.dev/cloud/guides/auto-updates-tauri/)

### Database Strategy
- [Switch SQLite/PostgreSQL based on MIX_ENV](https://blog.mnishiguchi.com/switch-between-sqlite-and-postgresql-based-on-mixenv-in-elixir-phoenix/)
- [Phoenix + SQLite Deployment Tips](https://gist.github.com/mcrumm/98059439c673be7e0484589162a54a01)
