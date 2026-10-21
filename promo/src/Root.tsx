import { Composition } from "remotion";
import { Demo, FPS, HEIGHT, SCENE, WIDTH } from "./Demo";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="MacDemo" component={Demo} defaultProps={{ platform: "mac" as const }}
        durationInFrames={SCENE * 3} fps={FPS} width={WIDTH} height={HEIGHT} />
      <Composition id="WindowsDemo" component={Demo} defaultProps={{ platform: "windows" as const }}
        durationInFrames={SCENE * 3} fps={FPS} width={WIDTH} height={HEIGHT} />
    </>
  );
};
