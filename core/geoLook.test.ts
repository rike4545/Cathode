import { describe, expect, it } from "vitest";
import {
  GEO_RADIUS_KM,
  geoLookAngles,
  offsetDishFaceElevationDeg,
  refractionDeg,
  wrapDegrees360,
} from "./geoLook";

const at = (latitudeDeg: number, longitudeDeg: number, altitudeM = 0) => ({
  latitudeDeg,
  longitudeDeg,
  altitudeM,
});

describe("geoLookAngles against an independent reference", () => {
  // Expected values come from the same WGS84 geometry worked in a separate
  // Python implementation, not from this module.
  const cases = [
    {
      place: "London to Astra 19.2E",
      from: at(51.5074, -0.1278),
      slot: 19.2,
      az: 155.847,
      el: 28.346,
      skew: -14.88,
      range: 38752.8,
    },
    {
      place: "Los Angeles to DirecTV 101W",
      from: at(34.0522, -118.2437),
      slot: -101,
      az: 150.978,
      el: 46.334,
      skew: -23.815,
      range: 37314.4,
    },
    {
      place: "Sydney to Optus 156E",
      from: at(-33.8688, 151.2093),
      slot: 156,
      az: 8.559,
      el: 50.318,
      skew: 7.132,
      range: 37052.9,
    },
    {
      place: "Nairobi to Eutelsat 7E",
      from: at(-1.2921, 36.8219),
      slot: 7,
      az: 272.25,
      el: 55.2,
      skew: -87.415,
      range: 36769.3,
    },
    {
      place: "New York to Dish 119W",
      from: at(40.7128, -74.006),
      slot: -119,
      az: 236.908,
      el: 24.522,
      skew: 39.689,
      range: 39110.9,
    },
    {
      place: "Dubai to Arabsat 26E",
      from: at(25.2048, 55.2708),
      slot: 26,
      az: 232.802,
      el: 46.111,
      skew: 46.27,
      range: 37332.0,
    },
  ];

  for (const { place, from, slot, az, el, skew, range } of cases) {
    it(`given: ${place}, should: match the reference to 0.01°`, () => {
      const look = geoLookAngles(from, slot);
      expect(look.azimuthDeg).toBeCloseTo(az, 2);
      expect(look.elevationDeg).toBeCloseTo(el, 2);
      expect(look.skewDeg).toBeCloseTo(skew, 2);
      expect(look.rangeKm).toBeCloseTo(range, 0);
    });
  }
});

describe("geoLookAngles geometry", () => {
  it("given: standing under the satellite, should: put it at the zenith", () => {
    const look = geoLookAngles(at(0, 30), 30);
    expect(look.elevationDeg).toBeCloseTo(90, 3);
    expect(look.rangeKm).toBeCloseTo(GEO_RADIUS_KM - 6378.137, 2);
  });

  it("given: the same meridian in the north, should: point due south with no skew", () => {
    const look = geoLookAngles(at(45, 10), 10);
    expect(look.azimuthDeg).toBeCloseTo(180, 6);
    expect(look.skewDeg).toBeCloseTo(0, 6);
  });

  it("given: a satellite on the far side of the Earth, should: put it below the horizon", () => {
    expect(geoLookAngles(at(40, 0), 180).elevationDeg).toBeLessThan(0);
  });

  it("given: altitude, should: leave azimuth alone and barely move elevation", () => {
    const sea = geoLookAngles(at(45, 0), 20);
    const high = geoLookAngles(at(45, 0, 3000), 20);
    expect(high.azimuthDeg).toBeCloseTo(sea.azimuthDeg, 2);
    expect(Math.abs(high.elevationDeg - sea.elevationDeg)).toBeLessThan(0.05);
  });

  it("given: any inputs, should: keep skew inside (-90, 90] and azimuth inside [0, 360)", () => {
    for (let lat = -80; lat <= 80; lat += 20) {
      for (let slot = -180; slot <= 180; slot += 15) {
        const look = geoLookAngles(at(lat, 12), slot);
        expect(look.skewDeg).toBeGreaterThan(-90 - 1e-9);
        expect(look.skewDeg).toBeLessThanOrEqual(90 + 1e-9);
        expect(look.azimuthDeg).toBeGreaterThanOrEqual(0);
        expect(look.azimuthDeg).toBeLessThan(360);
      }
    }
  });
});

describe("refractionDeg", () => {
  it("given: a mid elevation, should: be negligible", () => {
    expect(refractionDeg(30)).toBeLessThan(0.03);
  });
  it("given: a low elevation, should: be noticeable", () => {
    expect(refractionDeg(2)).toBeGreaterThan(0.2);
  });
  it("given: a point well below the horizon, should: not correct", () => {
    expect(refractionDeg(-5)).toBe(0);
  });
});

describe("offsetDishFaceElevationDeg", () => {
  it("given: a 22.7° offset dish, should: tilt the face that far below the satellite", () => {
    expect(offsetDishFaceElevationDeg(28.3, 22.7)).toBeCloseTo(5.6, 9);
  });
  it("given: a prime-focus dish, should: match the satellite elevation", () => {
    expect(offsetDishFaceElevationDeg(40, 0)).toBe(40);
  });
});

describe("wrapDegrees360", () => {
  it("given: negative, large and exactly-full-turn angles, should: land in [0, 360)", () => {
    expect(wrapDegrees360(-10)).toBe(350);
    expect(wrapDegrees360(370)).toBe(10);
    expect(wrapDegrees360(360)).toBe(0);
    expect(wrapDegrees360(-1e-15)).toBe(0);
  });
});
