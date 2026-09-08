import { convertToExcalidrawElements } from "@excalidraw/excalidraw";
import { loadPrefs } from "./prefs";
import type { AppSettings, Capture } from "./types";

// Canvas colors follow the system: dark = black canvas + white pen; light = white + dark pen.
// (The screenshot itself always renders faithfully — the canvas stays in Excalidraw's light theme.)
export function canvasColors(s: AppSettings): { bg: string; stroke: string } {
  if (s.dark) return { bg: "#121212", stroke: "#ffffff" };
  return { bg: "#ffffff", stroke: "#1e1e1e" };
}

// Common appState for every scene: theme default stroke, overridden by persisted tool prefs,
// then the canvas background/grid from settings.
export function sceneAppState(bg: string, grid: boolean, stroke: string) {
  return {
    currentItemStrokeColor: stroke,
    ...loadPrefs(),
    viewBackgroundColor: bg,
    gridModeEnabled: grid,
    theme: "light" as any,
    scrollX: 0,
    scrollY: 0,
    zoom: { value: 1 as any },
  };
}

// The locked screenshot background: a file entry to add + the image element to place at origin.
export function frozenBackground(cap: Capture): { file: any; element: any } {
  const fileId = `snapshot-${Date.now()}`;
  const file = {
    id: fileId,
    mimeType: "image/png",
    dataURL: cap.dataUrl,
    created: Date.now(),
  };
  const [element] = convertToExcalidrawElements([
    {
      type: "image",
      x: 0,
      y: 0,
      width: cap.logicalW,
      height: cap.logicalH,
      fileId: fileId as any,
    } as any,
  ]).map((el) => ({ ...el, locked: true }));
  return { file, element };
}
