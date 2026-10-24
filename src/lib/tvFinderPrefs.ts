// What the TV satellite finder remembers between visits: which satellite was
// picked, any custom longitude typed in, and the dish's offset angle.
//
// Kept as the raw strings the person typed, so a half-finished entry is not
// rewritten under them; the finder parses on use.

const STORAGE_KEY = "dishylink-tv-finder";

export interface TvFinderPrefs {
  /** A catalogue anchor id, or "custom" for a typed longitude. Null before any choice. */
  slotId: string | null;
  customText: string;
  offsetText: string;
}

export const DEFAULT_TV_FINDER_PREFS: TvFinderPrefs = {
  slotId: null,
  customText: "",
  offsetText: "",
};

export function loadTvFinderPrefs(): TvFinderPrefs {
  try {
    const parsed = JSON.parse(
      localStorage.getItem(STORAGE_KEY) ?? "null",
    ) as Partial<TvFinderPrefs> | null;
    if (!parsed || typeof parsed !== "object") return DEFAULT_TV_FINDER_PREFS;
    return {
      slotId: typeof parsed.slotId === "string" ? parsed.slotId : null,
      customText: typeof parsed.customText === "string" ? parsed.customText : "",
      offsetText: typeof parsed.offsetText === "string" ? parsed.offsetText : "",
    };
  } catch {
    return DEFAULT_TV_FINDER_PREFS; // unset, corrupt or blocked
  }
}

export function saveTvFinderPrefs(prefs: TvFinderPrefs): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    // storage blocked or full: the choices simply will not persist
  }
}
