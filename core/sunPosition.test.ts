import { describe, expect, it } from "vitest";
import { sunPosition } from "./sunPosition";

describe("sunPosition", () => {
  // Reference values from an independent Python implementation of the NOAA
  // algorithm.
  it("given: solar noon at the Tropic of Cancer at the June solstice, should: be nearly overhead", () => {
    const sun = sunPosition(new Date("2026-06-21T12:00:00Z"), 23.44, 0);
    expect(sun.elevationDeg).toBeCloseTo(89.58, 1);
  });

  it("given: London at midday on the March equinox, should: be south at about 38.6°", () => {
    const sun = sunPosition(new Date("2024-03-20T12:00:00Z"), 51.5074, -0.1278);
    expect(sun.azimuthDeg).toBeCloseTo(177.5, 1);
    expect(sun.elevationDeg).toBeCloseTo(38.61, 1);
  });

  it("given: local midnight, should: be below the horizon", () => {
    const sun = sunPosition(new Date("2026-06-21T00:00:00Z"), 51.5, 0);
    expect(sun.elevationDeg).toBeLessThan(0);
  });

  it("given: any time, should: return an azimuth inside [0, 360)", () => {
    for (let hour = 0; hour < 24; hour += 3) {
      const sun = sunPosition(new Date(Date.UTC(2026, 9, 21, hour)), -33.9, 151.2);
      expect(sun.azimuthDeg).toBeGreaterThanOrEqual(0);
      expect(sun.azimuthDeg).toBeLessThan(360);
    }
  });
});
