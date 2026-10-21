# Mangosteen promo animations

Remotion project for the looping demo videos in the READMEs: one scene per wheel (Convert, Tools, Actions),
dark theme, 1600 × 1000 at 30 fps. The `MacDemo` composition shows drag + key; `WindowsDemo` shows key + right-click.

```bash
npm i
swift scripts/export-assets.swift <photo.jpg>            # SF Symbols, Finder icons, photo thumbnail
swift scripts/export-assets.swift <video-frame.jpg> video-thumb
npx remotion studio                                       # preview
npx remotion render MacDemo out/MacDemo.mp4 --codec=h264 --crf=10 --scale=2 --image-format=png   # 3200 × 2000
```

README animation (looping WebP, 1600 px, 30 fps, made from lossless PNG frames):

```bash
npx remotion render MacDemo frames --sequence --image-format=png
img2webp -loop 0 -kmin 0 -kmax 1 -lossy -q 92 -m 6 -d 33 frames/element-*.png -o out/MacDemo.webp
```

`public/mac-trim.png` is a snapshot of the app's Trim window (`Mangosteen --snapshot tool.trimMedia`);
`public/win-trim.png` comes from the Windows repo's README images.
