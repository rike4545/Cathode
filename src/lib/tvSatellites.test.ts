import { beforeEach, describe, expect, it, vi } from "vitest";
import { setTvSatellitesEnabled, subscribeTvSatellites, tvSatellitesEnabled } from "./tvSatellites";

function stubStorage() {
  const store = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  });
}

describe("tvSatellites preference", () => {
  beforeEach(() => stubStorage());

  it("given: nothing stored, should: be off", () => {
    expect(tvSatellitesEnabled()).toBe(false);
  });

  it("given: it was turned on, should: read back on, and off again after", () => {
    setTvSatellitesEnabled(true);
    expect(tvSatellitesEnabled()).toBe(true);
    setTvSatellitesEnabled(false);
    expect(tvSatellitesEnabled()).toBe(false);
  });

  it("given: a subscriber, should: be told on every change until it unsubscribes", () => {
    const listener = vi.fn();
    const unsubscribe = subscribeTvSatellites(listener);
    setTvSatellitesEnabled(true);
    setTvSatellitesEnabled(false);
    expect(listener).toHaveBeenCalledTimes(2);
    unsubscribe();
    setTvSatellitesEnabled(true);
    expect(listener).toHaveBeenCalledTimes(2);
  });

  it("given: blocked storage, should: stay off and not throw", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    });
    expect(tvSatellitesEnabled()).toBe(false);
    expect(() => setTvSatellitesEnabled(true)).not.toThrow();
  });
});
