# 工作台背景资源

## 当前明暗背景

`cyan-amber.png` 是首页青蓝与琥珀流体背景的生成原图，`../../Resources/Workbench/cyan-amber.jpg` 是界面采用的压缩资源。两者的 SHA-256 见 `provenance-fluid.json`。JPEG 保持设计使用的图像内容及比例；运行时按窗口大小等比覆盖裁切，焦点为水平 50%、垂直 43%。图像不包含界面、账号信息或设备读数。

所有工作台页面及顶部导航在浅色下采用青蓝琥珀，深色下采用墨金。`ink-gold.png` 是墨金生成原图，`../../Resources/Workbench/ink-gold.jpg` 为已采用的压缩资源，指纹见 `provenance-dark.json`。深色背景等比覆盖、居中裁切。两套图片均不含界面文字、账号或读数。

以下旧资源仅保留历史与配置兼容，不再提供主题选择入口。

## 既有山景背景

本目录保存与三款圆角水镜图标配套的完整仙山背景：青碧晨雾、月白云海、暖霞悬山。这些曾用于旧主题；AR 世界与雷霆机舱也作为历史资源保留。

三个 PNG 均为生成器原始文件，实际尺寸为 **1672 × 941**，无透明通道。精确生成提示词、参考图标、源图与生产资源 SHA-256 见 `provenance.json`。提示词中的理想分辨率不代表实际输出尺寸；素材没有放大、裁切或重新绘制。

生产资源仅使用 macOS `sips` 以质量 95 编码为 JPEG，尺寸保持不变。在仓库根目录重建：

```sh
for name in qingbi-chenwu yuebai-yunhai nuanxia-xuanshan; do
    sips -s format jpeg -s formatOptions 95 \
        "Launcher/Artwork/Workbench/$name.png" \
        --out "Launcher/Resources/Workbench/$name.jpg"
done
```

AR 世界、雷霆机舱的既有 JPEG 不由这组来源重建。本目录仅包含正式采用的背景及其来源记录。
