# 方寸应用图标

## Desktop outline

The current icon is **桌面** (`desk`): a dark gray work window and desk outline on a light warm tile. The Dock, Finder and application switcher use the same default artwork. In-app branding uses a separate optical-size drawing at 32 pt and below; larger branding uses the main icon. The menu bar has an independent transparent monochrome template, with native 18 pt representations at 1x and 2x.

`Desk/` keeps the editable SVG masters, ten approved standard iconset PNG representations, panel artwork and 1x/2x branding/template PNGs. These final raster sources are retained at their approved resolutions so packaging does not redraw or resample the design. The SVGs support future edits; any artwork change must include newly reviewed raster representations. No historical design gallery or personal screenshot is required to rebuild.

Run `swift Launcher/scripts/prepare-app-icons.swift` from the repository root, then `Launcher/scripts/check-app-icons.sh`. The packaging tool combines the approved iconset with `iconutil`, copies branding/template pixels directly, and writes `provenance-desk.json` with source and production SHA-256 values. `Resources/AppIcon.icns` is byte-identical to `Resources/AppIcons/desk.icns`. The build scripts package these current resources and verify their exact contents.

Previous icon preferences migrate to `desk` after its artwork loads successfully. This updates the running Dock and window branding without writing into a signed application bundle. Finder receives the new default icon when the newly built app is installed.

The sections below describe historical artwork; their original files and provenance remain unchanged.

## 历史山水图标

本目录保存三幅圆角方形水镜图标的原始位图：青碧晨雾、月白云海、暖霞悬山。晶莹水镜中容纳云雾仙山，四边等长，没有水滴尖角。三个原图均为 1254 × 1254 像素，保留真实透明通道，并逐字节保存生成结果；精确提示词、尺寸、指纹及参考图来源见 `provenance.json`。

历史转换只进行透明画布上的等比例缩放与居中，不裁切、不拉伸，也不修改画面。三个历史 ICNS 文件各包含 16–1024 像素的十个标准表示；该阶段默认图标为青碧晨雾。对应完整山水背景的可重建来源保存在 `../Workbench/`。

早期水滴形图标继续保留在 Git 历史及对应正式版本归档中；当前目录使用圆角水镜版本。

该阶段的应用图标选择保存在本机偏好中，启动时恢复，并通过 AppKit 更新运行中的程序坞与应用切换器图标，不会向已签名的 App 包写入资源。


## Historical minimal geometric marks

The previous application offered **墨白** (`minimal-ink`) and **留白** (`minimal-frame`). Their original 1024-pixel PNGs, ICNS files and menu-bar marks are preserved. The former vector construction is available in Git history; the current packaging script prepares the desktop outline above.

`provenance-minimal.json` records that stage's source, production and menu-bar hashes. The mountain originals and `provenance.json` above describe the older artwork and remain unchanged.
