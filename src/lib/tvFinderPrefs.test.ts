import { beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_TV_FINDER_PREFS, loadTvFinderPrefs, saveTvFinderPrefs } from "./tvFinderPrefs";

function stubStorage(initial?: string) {
  const store = new Map<string, string>();
  if (initial !== undefined) store.set("dishylink-tv-finder", initial);
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  });
}

describe("tvFinderPrefs", () => {
  beforeEach(() => stubStorage());

  it("given: nothing stored, should: return the defaults", () => {
    expect(loadTvFinderPrefs()).toEqual(DEFAULT_TV_FINDER_PREFS);
  });

  it("given: saved choices, should: read them back unchanged", () => {
    saveTvFinderPrefs({ slotId: "Hot Bird@13", customText: "19,", offsetText: "22.7" });
    expect(loadTvFinderPrefs()).toEqual({
      slotId: "Hot Bird@13",
      customText: "19,",
      offsetText: "22.7",
    });
  });

  it("given: corrupt JSON, should: fall back to the defaults", () => {
    stubStorage("{not json");
    expect(loadTvFinderPrefs()).toEqual(DEFAULT_TV_FINDER_PREFS);
  });

  it("given: stored values of the wrong type, should: ignore them field by field", () => {
    stubStorage(JSON.stringify({ slotId: 5, customText: "19.2", offsetText: null }));
    expect(loadTvFinderPrefs()).toEqual({ slotId: null, customText: "19.2", offsetText: "" });
  });

  it("given: blocked storage, should: not throw on read or write", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    });
    expect(loadTvFinderPrefs()).toEqual(DEFAULT_TV_FINDER_PREFS);
    expect(() => saveTvFinderPrefs(DEFAULT_TV_FINDER_PREFS)).not.toThrow();
  });
});
