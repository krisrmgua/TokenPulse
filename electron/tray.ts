import { nativeImage } from "electron";
import { renderMark } from "./iconRaster";

/** macOS: black template image so the menu bar tints it. Windows: cyan mark. */
export function createTrayIcon(): Electron.NativeImage {
  if (process.platform === "darwin") {
    const image = nativeImage.createFromBuffer(
      renderMark({ size: 36, variant: "tray", color: [0, 0, 0] }),
      { scaleFactor: 2 },
    );
    image.setTemplateImage(true);
    return image;
  }
  return nativeImage.createFromBuffer(renderMark({ size: 32, variant: "tray" }), {
    scaleFactor: 2,
  });
}
