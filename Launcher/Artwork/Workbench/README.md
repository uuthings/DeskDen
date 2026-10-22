# 方寸山主题背景

本目录保存与三款圆角水镜图标配套的完整仙山背景：青碧晨雾、月白云海、暖霞悬山。默认主题为青碧晨雾；既有 AR 世界与雷霆机舱继续保留。

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
