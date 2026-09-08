// Persist Excalidraw's tool defaults (color, stroke width, font, ...) so they carry across
// sessions and modes, like the real Excalidraw app.

const PREFS_KEY = "excali-prefs";

const PREF_KEYS = [
  "currentItemStrokeColor",
  "currentItemBackgroundColor",
  "currentItemFillStyle",
  "currentItemStrokeWidth",
  "currentItemStrokeStyle",
  "currentItemRoughness",
  "currentItemOpacity",
  "currentItemFontFamily",
  "currentItemFontSize",
  "currentItemTextAlign",
  "currentItemStartArrowhead",
  "currentItemEndArrowhead",
  "currentItemRoundness",
  "currentItemArrowType",
] as const;

export function savePrefs(appState: Record<string, unknown>): void {
  try {
    const prefs: Record<string, unknown> = {};
    for (const key of PREF_KEYS) {
      if (appState[key] !== undefined) prefs[key] = appState[key];
    }
    localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
  } catch {
    /* ignore */
  }
}

export function loadPrefs(): Record<string, unknown> {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}
