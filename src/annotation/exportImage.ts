import { exportToBlob } from "@excalidraw/excalidraw";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";

function blobToDataURL(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error);
    reader.onload = () => resolve(reader.result as string);
    reader.readAsDataURL(blob);
  });
}

/// Flatten the current scene to a PNG data URL at the given device scale (null if empty).
export async function flattenToPng(
  api: ExcalidrawImperativeAPI,
  scale: number,
): Promise<string | null> {
  const elements = api.getSceneElements();
  if (elements.length === 0) return null;
  const blob = await exportToBlob({
    elements,
    appState: { ...api.getAppState(), exportBackground: false, exportEmbedScene: false },
    files: api.getFiles(),
    mimeType: "image/png",
    getDimensions: (w: number, h: number) => ({ width: w * scale, height: h * scale, scale }),
  });
  return blobToDataURL(blob);
}
