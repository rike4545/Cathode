import { describe, expect, it } from "vitest";
import { GEO_SATELLITES, formatOrbitalLongitude, visibleGeoSatellites } from "./geoCatalog";

describe("formatOrbitalLongitude", () => {
  it("given: east, west, fractional and zero longitudes, should: label them", () => {
    expect(formatOrbitalLongitude(19.2)).toBe("19.2°E");
    expect(formatOrbitalLongitude(-119)).toBe("119°W");
    expect(formatOrbitalLongitude(-0.8)).toBe("0.8°W");
    expect(formatOrbitalLongitude(0)).toBe("0°");
  });
});

describe("visibleGeoSatellites", () => {
  const london = { latitudeDeg: 51.5, longitudeDeg: -0.1, altitudeM: 0 };

  it("given: London, should: include the 28.2°E slot used by UK TV", () => {
    expect(
      visibleGeoSatellites(london).some(({ satellite }) => satellite.longitudeDeg === 28.2),
    ).toBe(true);
  });

  it("given: London, should: not include a Pacific slot below the horizon", () => {
    expect(
      visibleGeoSatellites(london).some(({ satellite }) => satellite.longitudeDeg === -129),
    ).toBe(false);
  });

  it("given: any spot, should: list the highest satellites first", () => {
    const elevations = visibleGeoSatellites(london).map(({ look }) => look.elevationDeg);
    expect(elevations).toEqual([...elevations].sort((first, second) => second - first));
  });

  it("given: a higher floor, should: return fewer satellites", () => {
    expect(visibleGeoSatellites(london, 30).length).toBeLessThan(
      visibleGeoSatellites(london, 5).length,
    );
  });
});

describe("the catalogue", () => {
  it("given: every entry, should: be a valid orbital longitude", () => {
    for (const { longitudeDeg } of GEO_SATELLITES) {
      expect(longitudeDeg).toBeGreaterThanOrEqual(-180);
      expect(longitudeDeg).toBeLessThanOrEqual(180);
    }
  });
});
