// Whether the sky view draws the geostationary arc and its TV-satellite slots.
//
// A stored choice shared across surfaces, built like the dome-trim one: either
// surface can set it and every subscriber follows, with no flag threaded through
// the tree in between.

const STORAGE_KEY = "dishylink-tv-satellites";

const listeners = new Set<() => void>();

/** Off unless it has been turned on, so an untouched install looks as it always did. */
export function tvSatellitesEnabled(): boolean {
  try {
    return typeof localStorage !== "undefined" && localStorage.getItem(STORAGE_KEY) === "on";
  } catch {
    return false; // storage blocked: behave as unset
  }
}

export function setTvSatellitesEnabled(enabled: boolean): void {
  try {
    localStorage.setItem(STORAGE_KEY, enabled ? "on" : "off");
  } catch {
    // storage blocked or full: the toggle simply will not persist
  }
  for (const listener of listeners) listener();
}

export function subscribeTvSatellites(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
