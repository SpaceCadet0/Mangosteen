import React from "react";
import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";

export type Platform = "mac" | "windows";

export const FPS = 30;
export const SCENE = 126; // 4.2 s per wheel
export const WIDTH = 1600;
export const HEIGHT = 1000;

const BRAND = "#671E38";
const smooth = Easing.bezier(0.45, 0, 0.2, 1);
const pop = Easing.bezier(0.34, 1.56, 0.64, 1);

/** Clamped interpolation with an easing. */
const tween = (
  frame: number,
  range: [number, number],
  output: [number, number],
  easing = smooth,
) =>
  interpolate(frame, range, output, {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing,
  });

// MARK: - Scenes

type Segment = { title: string; icon: string };
type Scene = {
  kind: string;
  key: { mac: [string, string]; windows: string };
  files: { name: string; icon: string; thumb?: boolean }[];
  segments: Record<Platform, Segment[]>;
  target: Record<Platform, number>;
  start: Record<Platform, number>; // segment the pointer first enters
  result: "file" | "window" | "float";
};

const photo = (title: string): Segment => ({ title, icon: "sf-photo" });
const both = (segments: Segment[]): Record<Platform, Segment[]> => ({
  mac: segments,
  windows: segments,
});

/** Video tool titles in wheel order; icons follow the position (Trim, Split, Speed, Volume, Bleep, Hide, Crop, Compress, Frames). */
const videoTools = (titles: string[]): Segment[] => {
  const icons = [
    "sf-timeline-selection",
    "sf-scissors",
    "sf-gauge-with-dots-needle-67percent",
    "sf-speaker-wave-3",
    "sf-waveform-badge-minus",
    "sf-eye-slash",
    "sf-crop",
    "sf-arrow-down-right-and-arrow-up-left",
    "sf-photo-on-rectangle",
  ];
  return titles.map((title, index) => ({ title, icon: icons[index] }));
};

const actions: Segment[] = [
  { title: "Float", icon: "sf-tray-and-arrow-down" },
  { title: "Copy", icon: "sf-doc-on-clipboard" },
  { title: "Move", icon: "sf-folder" },
  { title: "Path", icon: "sf-link" },
  { title: "Terminal", icon: "sf-terminal" },
];

const SCENES: Scene[] = [
  {
    kind: "Convert",
    key: { mac: ["⇧", "shift"], windows: "Shift" },
    files: [{ name: "photo.heic", icon: "photo-thumb", thumb: true }],
    segments: both([
      photo("PNG"),
      photo("JPG"),
      photo("WebP"),
      photo("TIFF"),
      photo("AVIF"),
      photo("BMP"),
      photo("GIF"),
      { title: "PDF", icon: "sf-doc-richtext" },
    ]),
    target: { mac: 1, windows: 1 },
    start: { mac: 3, windows: 3 },
    result: "file",
  },
  {
    kind: "Tools",
    key: { mac: ["⌘", "command"], windows: "Ctrl" },
    files: [{ name: "Mangosteen.mp4", icon: "video-thumb", thumb: true }],
    // The real wheels for one video file, clockwise from the top.
    segments: {
      mac: videoTools([
        "Trim",
        "Split",
        "Speed",
        "Loudness",
        "Bleep",
        "Redact",
        "Crop video",
        "Compress",
        "Frames",
      ]),
      windows: videoTools([
        "Trim",
        "Split",
        "Speed",
        "Volume",
        "Bleep",
        "Hide",
        "Reframe",
        "Compress",
        "Frames",
      ]),
    },
    target: { mac: 0, windows: 0 },
    start: { mac: 2, windows: 2 },
    result: "window",
  },
  {
    kind: "Actions",
    key: { mac: ["⌃", "control"], windows: "Alt" },
    files: [
      { name: "photo.heic", icon: "photo-thumb", thumb: true },
      { name: "song.mp3", icon: "finder-mp3" },
    ],
    // Windows has no AirDrop.
    segments: {
      mac: [
        { title: "AirDrop", icon: "sf-dot-radiowaves-left-and-right" },
        ...actions,
      ],
      windows: actions,
    },
    target: { mac: 1, windows: 0 },
    start: { mac: 3, windows: 2 },
    result: "float",
  },
];

// MARK: - Wheel geometry (matches the apps)

type WheelStyle = {
  outer: number;
  inner: number;
  disc: string;
  border?: string;
  ring: string;
  segment: string;
  hub: string;
  text: string;
  secondary: string;
  font: string;
};

const WHEEL: Record<Platform, WheelStyle> = {
  mac: {
    outer: 160,
    inner: 64,
    disc: "rgba(36,36,38,0.97)",
    ring: "rgba(255,255,255,0.03)",
    segment: "rgba(255,255,255,0.06)",
    hub: "transparent",
    text: "#ECECEE",
    secondary: "#9A9AA0",
    font: "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif",
  },
  windows: {
    outer: 150,
    inner: 64,
    disc: "#1C1C1E",
    border: "#3A3A3D",
    ring: "transparent",
    segment: "#2C2C2F",
    hub: "#222224",
    text: "#E6E6EA",
    secondary: "#9A9AA0",
    font: "'Segoe UI', -apple-system, 'Helvetica Neue', sans-serif",
  },
};

const WHEEL_SCALE = 1.55;

/** Point at `radius` and `angle` (radians, 0 at the top, clockwise). */
const polar = (cx: number, cy: number, radius: number, angle: number) => ({
  x: cx + radius * Math.sin(angle),
  y: cy - radius * Math.cos(angle),
});

/** A ring segment drawn inset by the corner radius; a round-joined stroke of the same colour rounds it off. */
const segmentPath = (
  cx: number,
  cy: number,
  inner: number,
  outer: number,
  start: number,
  end: number,
) => {
  const corner = 10;
  const gap = 6;
  const ro = outer - 4 - corner;
  const ri = inner + 4 + corner;
  const inset = (r: number) => (gap / 2 + corner) / r;
  const steps = 18;
  const points: string[] = [];
  for (let i = 0; i <= steps; i++) {
    const a =
      start + inset(ro) + (end - inset(ro) - (start + inset(ro))) * (i / steps);
    const p = polar(cx, cy, ro, a);
    points.push(`${p.x.toFixed(2)},${p.y.toFixed(2)}`);
  }
  for (let i = steps; i >= 0; i--) {
    const a =
      start + inset(ri) + (end - inset(ri) - (start + inset(ri))) * (i / steps);
    const p = polar(cx, cy, ri, a);
    points.push(`${p.x.toFixed(2)},${p.y.toFixed(2)}`);
  }
  return `M${points.join("L")}Z`;
};

const Wheel: React.FC<{
  platform: Platform;
  scene: Scene;
  highlighted: number | null;
  hubHover: boolean;
  fileCount: number;
}> = ({ platform, scene, highlighted, hubHover, fileCount }) => {
  const s = WHEEL[platform];
  const size = (s.outer + 24) * 2;
  const c = size / 2;
  const segments = scene.segments[platform];
  const span = (Math.PI * 2) / segments.length;
  const label = 0.5 * (s.inner + s.outer);
  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      style={{ overflow: "visible" }}
    >
      <defs>
        <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">
          <feDropShadow
            dx="0"
            dy="6"
            stdDeviation="12"
            floodColor="#000"
            floodOpacity="0.45"
          />
        </filter>
      </defs>
      <circle
        cx={c}
        cy={c}
        r={s.outer}
        fill={s.disc}
        stroke={s.border}
        strokeWidth={s.border ? 1.5 : 0}
        filter="url(#shadow)"
      />
      <path
        d={`M${c - (s.outer - 4)},${c}a${s.outer - 4},${s.outer - 4} 0 1,0 ${2 * (s.outer - 4)},0a${s.outer - 4},${s.outer - 4} 0 1,0 ${-2 * (s.outer - 4)},0
            M${c - (s.inner + 4)},${c}a${s.inner + 4},${s.inner + 4} 0 1,0 ${2 * (s.inner + 4)},0a${s.inner + 4},${s.inner + 4} 0 1,0 ${-2 * (s.inner + 4)},0`}
        fill={s.ring}
        fillRule="evenodd"
      />
      {platform === "windows" && (
        <circle cx={c} cy={c} r={s.inner - 4} fill={hubHover ? BRAND : s.hub} />
      )}
      {segments.map((segment, index) => {
        const start = index * span - span / 2;
        const isOn = highlighted === index;
        const fill = isOn ? BRAND : s.segment;
        const d = segmentPath(c, c, s.inner, s.outer, start, start + span);
        const at = polar(c, c, label, index * span);
        return (
          <g key={segment.title}>
            <path
              d={d}
              fill={fill}
              stroke={fill}
              strokeWidth={20}
              strokeLinejoin="round"
            />
            <image
              href={staticFile(`icons/${segment.icon}.png`)}
              x={at.x - 12}
              y={at.y - 25}
              width={24}
              height={20}
              preserveAspectRatio="xMidYMid meet"
              opacity={isOn ? 1 : 0.88}
            />
            <text
              x={at.x}
              y={at.y + 14}
              textAnchor="middle"
              fill={isOn ? "#fff" : s.text}
              style={{ font: `600 11.5px ${s.font}` }}
            >
              {segment.title}
            </text>
          </g>
        );
      })}
      <text
        x={c}
        y={c - 1}
        textAnchor="middle"
        fill="#fff"
        style={{ font: `700 ${platform === "mac" ? 12.5 : 14}px ${s.font}` }}
      >
        {scene.kind}
      </text>
      <text
        x={c}
        y={c + 15}
        textAnchor="middle"
        fill={s.secondary}
        style={{ font: `400 11px ${s.font}` }}
      >
        {fileCount === 1 ? "1 file" : `${fileCount} files`}
      </text>
    </svg>
  );
};

// MARK: - Small parts

const Cursor: React.FC<{ platform: Platform; pressed: boolean }> = ({
  platform,
  pressed,
}) => (
  <svg
    width={34}
    height={46}
    viewBox="0 0 17 23"
    style={{ scale: pressed ? "0.9" : "1", transformOrigin: "2px 2px" }}
  >
    <path
      d="M1.5 1.5 L1.5 18.5 L5.6 14.6 L8.4 21 L11.1 19.8 L8.4 13.6 L14 13.6 Z"
      fill={platform === "mac" ? "#000" : "#fff"}
      stroke={platform === "mac" ? "#fff" : "#000"}
      strokeWidth={1.2}
      strokeLinejoin="round"
    />
  </svg>
);

const FileIcon: React.FC<{
  platform: Platform;
  file: Scene["files"][number];
  selected: boolean;
  size?: number;
  showName?: boolean;
}> = ({ platform, file, selected, size = 128, showName = true }) => {
  const extension = file.name.split(".").pop()!.toUpperCase();
  const picture =
    platform === "mac" || file.thumb ? (
      <Img
        src={staticFile(`icons/${file.icon}.png`)}
        style={{ width: size, height: size, objectFit: "contain" }}
      />
    ) : (
      // A Windows-style document: white page, folded corner, coloured type band.
      <svg width={size} height={size} viewBox="0 0 64 64">
        <path d="M14 4h26l12 12v44H14z" fill="#F3F3F3" />
        <path d="M40 4v12h12" fill="#D5D5D5" />
        <rect x="8" y="34" width="36" height="16" rx="2" fill={BRAND} />
        <text
          x="26"
          y="45.5"
          textAnchor="middle"
          fill="#fff"
          style={{ font: "700 9px 'Segoe UI', sans-serif" }}
        >
          {extension}
        </text>
      </svg>
    );
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 6,
        width: size + 60,
      }}
    >
      <div
        style={{
          padding: 6,
          borderRadius: platform === "mac" ? 10 : 4,
          background: selected
            ? platform === "mac"
              ? "rgba(255,255,255,0.12)"
              : "rgba(76,160,255,0.22)"
            : "transparent",
          outline:
            selected && platform === "windows"
              ? "1.5px solid rgba(110,180,255,0.65)"
              : "none",
        }}
      >
        {picture}
      </div>
      {showName && (
        <div
          style={{
            font: `500 21px ${WHEEL[platform].font}`,
            color: "#fff",
            padding: "2px 8px",
            borderRadius: platform === "mac" ? 6 : 2,
            background: selected
              ? platform === "mac"
                ? "#2F63D6"
                : "rgba(76,160,255,0.35)"
              : "transparent",
          }}
        >
          {file.name}
        </div>
      )}
    </div>
  );
};

const Keycap: React.FC<{
  platform: Platform;
  scene: Scene;
  pressed: number;
  showMouse: boolean;
}> = ({ platform, scene, pressed, showMouse }) => {
  const font = WHEEL[platform].font;
  const label =
    platform === "mac" ? (
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          lineHeight: 1,
        }}
      >
        <span style={{ fontSize: 30 }}>{scene.key.mac[0]}</span>
        <span style={{ fontSize: 22, marginTop: 8 }}>{scene.key.mac[1]}</span>
      </div>
    ) : (
      <span style={{ fontSize: 28 }}>{scene.key.windows}</span>
    );
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 26 }}>
      <div
        style={{
          width: 210,
          height: 112,
          borderRadius: 18,
          background: "linear-gradient(#3B3B40, #2A2A2E)",
          boxShadow: `0 ${10 - pressed * 7}px 0 #18181A, 0 ${16 - pressed * 8}px 28px rgba(0,0,0,0.5)`,
          translate: `0px ${pressed * 7}px`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: "#E8E8EC",
          font: `500 22px ${font}`,
          outline:
            pressed > 0.5 ? `2px solid ${BRAND}` : "2px solid transparent",
        }}
      >
        {label}
      </div>
      {showMouse && (
        <>
          <span style={{ color: "#9A9AA0", font: `600 34px ${font}` }}>+</span>
          <svg width={70} height={104} viewBox="0 0 35 52">
            <rect
              x="1.5"
              y="1.5"
              width="32"
              height="49"
              rx="16"
              fill="#2A2A2E"
              stroke="#4A4A50"
              strokeWidth="1.5"
            />
            <path
              d="M17.5 2 V20 H33 V17.5 A16 16 0 0 0 17.5 2 Z"
              fill={BRAND}
            />
            <line
              x1="17.5"
              y1="2"
              x2="17.5"
              y2="20"
              stroke="#4A4A50"
              strokeWidth="1.5"
            />
            <line
              x1="2"
              y1="20"
              x2="33"
              y2="20"
              stroke="#4A4A50"
              strokeWidth="1.5"
            />
          </svg>
        </>
      )}
    </div>
  );
};

const FloatPanel: React.FC<{ platform: Platform }> = ({ platform }) => {
  const font = WHEEL[platform].font;
  const rows = [
    { name: "photo.heic", icon: "photo-thumb" },
    { name: "song.mp3", icon: "finder-mp3" },
  ];
  return (
    <div
      style={{
        width: 330,
        padding: 18,
        borderRadius: platform === "mac" ? 16 : 8,
        background: "rgba(44,44,48,0.97)",
        border: "1px solid rgba(255,255,255,0.08)",
        boxShadow: "0 24px 60px rgba(0,0,0,0.55)",
        color: "#fff",
        font: `500 18px ${font}`,
        display: "flex",
        flexDirection: "column",
        gap: 12,
      }}
    >
      <div style={{ font: `700 21px ${font}` }}>Float · 2</div>
      <div
        style={{
          display: "flex",
          background: "rgba(255,255,255,0.08)",
          borderRadius: 8,
          padding: 3,
        }}
      >
        <div
          style={{
            flex: 1,
            textAlign: "center",
            padding: "6px 0",
            borderRadius: 6,
            background: "rgba(255,255,255,0.16)",
          }}
        >
          Copy
        </div>
        <div
          style={{
            flex: 1,
            textAlign: "center",
            padding: "6px 0",
            color: "#C8C8CE",
          }}
        >
          Move
        </div>
      </div>
      <div
        style={{
          padding: "10px 12px",
          borderRadius: 10,
          background: "rgba(255,255,255,0.07)",
          font: `700 18px ${font}`,
        }}
      >
        Drag all (2)
      </div>
      {rows.map((row) => (
        <div
          key={row.name}
          style={{ display: "flex", alignItems: "center", gap: 12 }}
        >
          <Img
            src={staticFile(`icons/${row.icon}.png`)}
            style={{ width: 46, height: 46, objectFit: "contain" }}
          />
          <span style={{ flex: 1 }}>{row.name}</span>
          <span style={{ color: "#8E8E94", fontSize: 20 }}>⊗</span>
        </div>
      ))}
    </div>
  );
};

// MARK: - One wheel scene

const FILE_X = 420;
const FILE_Y = 330;

const SceneView: React.FC<{ platform: Platform; scene: Scene }> = ({
  platform,
  scene,
}) => {
  const frame = useCurrentFrame();
  const s = WHEEL[platform];
  const mac = platform === "mac";
  const count = scene.files.length;

  // Timeline (frames inside the scene).
  const t = mac
    ? {
        reach: 16,
        grab: 20,
        drag: 40,
        key: 44,
        keyDown: 48,
        keyUp: 56,
        wheel: 50,
        move: 62,
        arrive: 92,
        act: 98,
      }
    : {
        reach: 16,
        grab: 20,
        drag: 20,
        key: 20,
        keyDown: 24,
        keyUp: 102,
        wheel: 34,
        move: 44,
        arrive: 80,
        act: 86,
      };

  // Where the wheel opens: next to the files on macOS (where the drag went), on the file on Windows.
  const anchor = mac ? { x: 860, y: 430 } : { x: FILE_X + 64, y: FILE_Y + 64 };
  const fileCenter = { x: FILE_X + 64 + (count - 1) * 95, y: FILE_Y + 64 };

  // Pointer path: from the bottom right to the file, (macOS) drag to the anchor, then around the ring.
  const segments = scene.segments[platform];
  const span = (Math.PI * 2) / segments.length;
  const ring = 0.5 * (s.inner + s.outer) * WHEEL_SCALE;
  const startAngle = scene.start[platform] * span;
  let targetAngle = scene.target[platform] * span;
  // Go the short way round.
  while (targetAngle - startAngle > Math.PI) targetAngle -= Math.PI * 2;
  while (startAngle - targetAngle > Math.PI) targetAngle += Math.PI * 2;

  let pointer: { x: number; y: number };
  if (frame < t.grab) {
    pointer = {
      x: tween(frame, [0, t.reach], [1180, fileCenter.x]),
      y: tween(frame, [0, t.reach], [820, fileCenter.y]),
    };
  } else if (mac && frame < t.move) {
    pointer = {
      x: tween(frame, [t.grab, t.drag], [fileCenter.x, anchor.x]),
      y: tween(frame, [t.grab, t.drag], [fileCenter.y, anchor.y]),
    };
  } else if (frame < t.move) {
    pointer = fileCenter;
  } else {
    const half = (t.move + t.arrive) / 2;
    const radius = tween(frame, [t.move, half - 4], [0, ring]);
    const angle = tween(frame, [half - 6, t.arrive], [startAngle, targetAngle]);
    pointer = polar(anchor.x, anchor.y, radius, angle);
  }

  // Which segment is under the pointer.
  const dx = pointer.x - anchor.x;
  const dy = pointer.y - anchor.y;
  const distance = Math.hypot(dx, dy) / WHEEL_SCALE;
  const wheelVisible = frame >= t.wheel && frame < t.act + 8;
  let highlighted: number | null = null;
  if (wheelVisible && distance >= s.inner && distance <= s.outer + 20) {
    const angle = (Math.atan2(dx, -dy) + Math.PI * 2) % (Math.PI * 2);
    highlighted = Math.round(angle / span) % segments.length;
  }

  const wheelOpacity = interpolate(
    frame,
    [t.wheel, t.wheel + 6, t.act + 2, t.act + 9],
    [0, 1, 1, 0],
    {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    },
  );
  const wheelScale =
    frame < t.act
      ? tween(frame, [t.wheel, t.wheel + 9], [0.82, 1], pop)
      : tween(frame, [t.act, t.act + 9], [1, 0.9]);

  const keyOpacity = interpolate(
    frame,
    [t.key - 6, t.key, t.act + 12, t.act + 20],
    [0, 1, 1, 0],
    {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    },
  );
  const keyPressed = interpolate(
    frame,
    [t.keyDown - 2, t.keyDown, t.keyUp, t.keyUp + 3],
    [0, 1, 1, 0],
    {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    },
  );

  const dragging = mac && frame >= t.grab && frame < t.act;
  const pressed = mac
    ? frame >= t.grab && frame < t.act
    : (frame >= 30 && frame < 34) || (frame >= t.act - 3 && frame < t.act + 1);
  const resultIn = tween(frame, [t.act + 4, t.act + 16], [0, 1], pop);
  const sceneOut = interpolate(frame, [SCENE - 10, SCENE], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const sceneIn = interpolate(frame, [0, 8], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  // Right-click and segment-click ripples (Windows).
  const ripple = (at: number) =>
    frame >= at && frame < at + 12
      ? tween(frame, [at, at + 12], [0, 1], Easing.out(Easing.quad))
      : null;
  const rightClick = !mac ? ripple(30) : null;
  const segmentClick = !mac ? ripple(t.act - 2) : null;

  return (
    <AbsoluteFill style={{ opacity: sceneIn * sceneOut }}>
      {/* Files on the desktop */}
      {scene.files.map((file, index) => (
        <div
          key={file.name}
          style={{
            position: "absolute",
            left: FILE_X - 30 + index * 190,
            top: FILE_Y,
          }}
        >
          <FileIcon
            platform={platform}
            file={file}
            selected={frame >= t.grab - 2}
          />
        </div>
      ))}

      {/* Result: the converted file next to the original */}
      {scene.result === "file" && frame >= t.act + 4 && (
        <div
          style={{
            position: "absolute",
            left: FILE_X - 30 + 190,
            top: FILE_Y,
            scale: String(resultIn),
            opacity: resultIn,
          }}
        >
          <FileIcon
            platform={platform}
            file={{ name: "photo.jpg", icon: "photo-thumb", thumb: true }}
            selected={false}
          />
        </div>
      )}

      {/* The wheel */}
      {wheelOpacity > 0 && (
        <div
          style={{
            position: "absolute",
            left: anchor.x - (s.outer + 24),
            top: anchor.y - (s.outer + 24),
            scale: String(WHEEL_SCALE * wheelScale),
            opacity: wheelOpacity,
          }}
        >
          <Wheel
            platform={platform}
            scene={scene}
            highlighted={highlighted}
            hubHover={false}
            fileCount={count}
          />
        </div>
      )}

      {/* Key (and right mouse button on Windows) */}
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          bottom: 70,
          display: "flex",
          justifyContent: "center",
          opacity: keyOpacity,
        }}
      >
        <Keycap
          platform={platform}
          scene={scene}
          pressed={keyPressed}
          showMouse={!mac}
        />
      </div>

      {/* Tool window */}
      {scene.result === "window" && frame >= t.act + 4 && (
        <AbsoluteFill
          style={{
            justifyContent: "center",
            alignItems: "center",
            opacity: resultIn,
          }}
        >
          <Img
            src={staticFile(mac ? "mac-trim.png" : "win-trim.png")}
            style={{
              width: mac ? 760 : 820,
              scale: String(0.9 + 0.1 * resultIn),
              filter: "drop-shadow(0 30px 60px rgba(0,0,0,0.6))",
              borderRadius: mac ? 12 : 8,
            }}
          />
        </AbsoluteFill>
      )}

      {/* Float shelf */}
      {scene.result === "float" && frame >= t.act + 4 && (
        <div
          style={{
            position: "absolute",
            right: 120,
            top: 250,
            translate: `${(1 - resultIn) * 200}px 0px`,
            opacity: resultIn,
          }}
        >
          <FloatPanel platform={platform} />
        </div>
      )}

      {/* Dragged files follow the pointer (macOS) */}
      {dragging && (
        <div
          style={{
            position: "absolute",
            left: pointer.x - 42,
            top: pointer.y - 42,
            opacity: 0.72,
          }}
        >
          {scene.files.map((file, index) => (
            <div
              key={file.name}
              style={{
                position: "absolute",
                left: index * 10,
                top: -index * 10,
              }}
            >
              <FileIcon
                platform={platform}
                file={file}
                selected={false}
                size={84}
                showName={false}
              />
            </div>
          ))}
          {count > 1 && (
            <div
              style={{
                position: "absolute",
                left: 96,
                top: -18,
                minWidth: 34,
                height: 34,
                borderRadius: 17,
                background: "#E5484D",
                color: "#fff",
                font: `700 20px ${s.font}`,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              {count}
            </div>
          )}
          {highlighted !== null && (
            <div
              style={{
                position: "absolute",
                left: 86,
                top: 70,
                width: 30,
                height: 30,
                borderRadius: 15,
                background: "#34C759",
                color: "#fff",
                font: `700 24px ${s.font}`,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              +
            </div>
          )}
        </div>
      )}

      {/* Click ripples (Windows) */}
      {[rightClick, segmentClick].map((p, index) =>
        p === null ? null : (
          <div
            key={index}
            style={{
              position: "absolute",
              left: pointer.x - 40,
              top: pointer.y - 40,
              width: 80,
              height: 80,
              borderRadius: 40,
              border: `3px solid ${index === 0 ? BRAND : "#fff"}`,
              scale: String(0.3 + 0.9 * p),
              opacity: 1 - p,
            }}
          />
        ),
      )}

      {/* Pointer */}
      {frame < t.act + 14 && (
        <div
          style={{
            position: "absolute",
            left: pointer.x - 3,
            top: pointer.y - 3,
            opacity:
              frame < t.act + 6
                ? 1
                : tween(frame, [t.act + 6, t.act + 14], [1, 0]),
          }}
        >
          <Cursor platform={platform} pressed={pressed} />
        </div>
      )}
    </AbsoluteFill>
  );
};

// MARK: - Whole video

export const Demo: React.FC<{ platform: Platform }> = ({ platform }) => (
  <AbsoluteFill
    style={{
      background:
        "radial-gradient(1200px 700px at 30% 20%, rgba(103,30,56,0.22), transparent 70%), radial-gradient(900px 600px at 85% 90%, rgba(103,30,56,0.12), transparent 70%), #121214",
    }}
  >
    {SCENES.map((scene, index) => (
      <Sequence
        key={scene.kind}
        from={index * SCENE}
        durationInFrames={SCENE}
        layout="absolute-fill"
      >
        <SceneView platform={platform} scene={scene} />
      </Sequence>
    ))}
  </AbsoluteFill>
);
