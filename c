name: Build unsigned IPA

on:
  push:
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Compile & package
        run: |
          mkdir -p build Payload
          xcrun -sdk iphoneos swiftc \
            -target arm64-apple-ios16.0.0 \
            -sdk "$(xcrun -sdk iphoneos --show-sdk-path)" \
            -O -swift-version 5 \
            -framework SwiftUI -framework UIKit -framework PhotosUI \
            -framework Security -framework Foundation \
            ClaudeStudio.swift -o build/ClaudeStudio

          APP=Payload/ClaudeStudio.app
          mkdir -p "$APP"
          cp build/ClaudeStudio "$APP/ClaudeStudio"

          cat > "$APP/Info.plist" <<'PLIST'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
           "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>CFBundleName</key><string>Claude Studio</string>
            <key>CFBundleDisplayName</key><string>Claude Studio</string>
            <key>CFBundleExecutable</key><string>ClaudeStudio</string>
            <key>CFBundleIdentifier</key><string>com.personal.claudestudio</string>
            <key>CFBundleShortVersionString</key><string>0.2</string>
            <key>CFBundleVersion</key><string>2</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>MinimumOSVersion</key><string>16.0</string>
            <key>UILaunchScreen</key><dict/>
            <key>UISupportedInterfaceOrientations</key>
            <array><string>UIInterfaceOrientationPortrait</string></array>
            <key>NSPhotoLibraryUsageDescription</key>
            <string>用于选择图片发送给 AI 进行多模态对话。</string>
          </dict></plist>
          PLIST

          zip -qr ClaudeStudio-unsigned.ipa Payload -X

      - uses: actions/upload-artifact@v4
        with:
          name: ClaudeStudio-ipa
          path: ClaudeStudio-unsigned.ipa
