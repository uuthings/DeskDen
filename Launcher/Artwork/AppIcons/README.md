# 方寸应用图标

当前默认图标与重建方式见下方“Minimal geometric marks”。下文山水图标描述与其指纹保留历史含义；当前脚本已用于生成新的几何标记。

## 历史山水图标

本目录保存三幅圆角方形水镜图标的原始位图：青碧晨雾、月白云海、暖霞悬山。晶莹水镜中容纳云雾仙山，四边等长，没有水滴尖角。三个原图均为 1254 × 1254 像素，保留真实透明通道，并逐字节保存生成结果；精确提示词、尺寸、指纹及参考图来源见 `provenance.json`。

历史转换只进行透明画布上的等比例缩放与居中，不裁切、不拉伸，也不修改画面。三个生产 ICNS 文件各包含 16–1024 像素的十个标准表示；`Resources/AppIcon.icns` 与默认的青碧晨雾相同。对应完整山水背景的可重建来源保存在 `../Workbench/`，背景与图标可分别选择。

早期水滴形图标继续保留在 Git 历史及对应正式版本归档中；当前目录使用圆角水镜版本。

设置中的应用图标选择保存在本机偏好中，启动时恢复，并通过 AppKit 更新运行中的程序坞与应用切换器图标。不会向已签名的 App 包写入资源；访达和安装包中的固定图标为默认的青碧晨雾。


## Minimal geometric marks

The current application offers **墨白** (`minimal-ink`) and **留白** (`minimal-frame`). Their editable vector construction lives in `../../scripts/prepare-app-icons.swift`; the script renders both 1024-pixel originals, ten standard ICNS representations, the default bundle icon, panel branding and transparent monochrome menu-bar marks. No scene image is used in either mark. Rebuild with `swift Launcher/scripts/prepare-app-icons.swift` from the repository root, then run `Launcher/scripts/check-app-icons.sh`.

`provenance-minimal.json` records current source, production and menu-bar hashes. The mountain originals and `provenance.json` above describe the historical accepted artwork and remain unchanged. Old saved selections map to an available current icon without deleting user preferences.
