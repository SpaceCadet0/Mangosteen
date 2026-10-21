import { Composition } from "remotion";
import { Demo, FPS, HEIGHT, SCENE, WIDTH } from "./Demo";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      {/* 1600 × 1000 for the READMEs */}
      <Composition
        id="MacDemo"
        component={Demo}
        defaultProps={{ platform: "mac" as const }}
        durationInFrames={SCENE * 3}
        fps={FPS}
        width={WIDTH}
        height={HEIGHT}
      />
      <Composition
        id="WindowsDemo"
        component={Demo}
        defaultProps={{ platform: "windows" as const }}
        durationInFrames={SCENE * 3}
        fps={FPS}
        width={WIDTH}
        height={HEIGHT}
      />
      {/* 1000 × 1000 for the welcome windows */}
      <Composition
        id="MacDemoSquare"
        component={Demo}
        defaultProps={{ platform: "mac" as const, layout: "square" as const }}
        durationInFrames={SCENE * 3}
        fps={FPS}
        width={1000}
        height={1000}
      />
      <Composition
        id="WindowsDemoSquare"
        component={Demo}
        defaultProps={{
          platform: "windows" as const,
          layout: "square" as const,
        }}
        durationInFrames={SCENE * 3}
        fps={FPS}
        width={1000}
        height={1000}
      />
    </>
  );
};
