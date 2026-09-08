/** Mirror of the Rust `Capture` struct (serde camelCase). */
export interface Capture {
  dataUrl: string;
  widthPx: number;
  heightPx: number;
  scaleFactor: number;
  logicalW: number;
  logicalH: number;
  looksBlack: boolean;
}

export interface AppSettings {
  gridEnabled?: boolean;
  dark?: boolean; // system dark mode (reported by the native side)
}

export type Mode = "idle" | "frozen" | "whiteboard" | "file";
