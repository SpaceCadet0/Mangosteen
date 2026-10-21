# Mangosteen promo animations

Remotion project for the looping demo videos in the READMEs: one scene per wheel (Convert, Tools, Actions),
dark theme, 1600 × 1000 at 30 fps. The `MacDemo` composition shows drag + key; `WindowsDemo` shows key + right-click.

```bash
npm i
swift scripts/export-assets.swift <photo.jpg>            # SF Symbols, Finder icons, photo thumbnail
swift scripts/export-assets.swift <video-frame.jpg> video-thumb
npx remotion studio                                       # preview
npx remotion render MacDemo out/MacDemo.mp4 --codec=h264 --crf=16
```

README animation (looping WebP, 1000 px, 25 fps):

```bash
ffmpeg -i out/MacDemo.mp4 -vf "fps=25,scale=1000:-1:flags=lanczos" frames/f%04d.png
img2webp -loop 0 -lossy -q 72 -m 4 -d 40 frames/f*.png -o out/MacDemo.webp
```

`public/mac-trim.png` is a snapshot of the app's Trim window (`Mangosteen --snapshot tool.trimMedia`);
`public/win-trim.png` comes from the Windows repo's README images.
