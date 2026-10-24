import { describe, expect, it } from "vitest";
import { geoLookAngles } from "@core/geoLook";
import { GEO_SHELL, buildGeoOverlay, skyDirectionToWorld } from "./geoBelt";

const london = { latitudeDeg: 51.5, longitudeDeg: -0.12, altitudeM: 0 };
const FLOATS_PER_VERTEX = 6;

describe("skyDirectionToWorld", () => {
  it("given: due north on the horizon, should: sit on the -z axis", () => {
    const [x, y, z] = skyDirectionToWorld(0, 0, 2);
    expect(x).toBeCloseTo(0, 9);
    expect(y).toBeCloseTo(0, 9);
    expect(z).toBeCloseTo(-2, 9);
  });

  it("given: due east on the horizon, should: sit on the +x axis", () => {
    const [x, , z] = skyDirectionToWorld(90, 0, 1);
    expect(x).toBeCloseTo(1, 9);
    expect(z).toBeCloseTo(0, 9);
  });

  it("given: the zenith, should: sit straight up at the radius", () => {
    expect(skyDirectionToWorld(123, 90, 1.6)[1]).toBeCloseTo(1.6, 9);
  });
});

describe("buildGeoOverlay", () => {
  it("given: London, should: draw whole segments with both ends on the shell", () => {
    const { lines } = buildGeoOverlay(london);
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.length % (2 * FLOATS_PER_VERTEX)).toBe(0);
    // Belt vertices all sit on the shell and above the ground.
    for (let offset = 0; offset < lines.length; offset += FLOATS_PER_VERTEX) {
      const [x, y, z] = [lines[offset], lines[offset + 1], lines[offset + 2]];
      expect(y).toBeGreaterThan(-1e-6);
      // Marker ends sit just off the shell; the arc itself sits on it.
      expect(Math.hypot(x, y, z)).toBeGreaterThan(GEO_SHELL * 0.9);
      expect(Math.hypot(x, y, z)).toBeLessThan(GEO_SHELL * 1.1);
    }
  });

  it("given: London, should: anchor the 28.2°E slot where the look angles say", () => {
    const { anchors } = buildGeoOverlay(london);
    const astra = anchors.find((anchor) => anchor.label === "28.2°E");
    expect(astra, "UK TV's slot is in view").toBeDefined();
    const look = geoLookAngles(london, 28.2);
    const expected = skyDirectionToWorld(look.azimuthDeg, look.elevationDeg, GEO_SHELL);
    expect(astra!.position[0]).toBeCloseTo(expected[0], 9);
    expect(astra!.position[1]).toBeCloseTo(expected[1], 9);
    expect(astra!.position[2]).toBeCloseTo(expected[2], 9);
    expect(astra!.title).toContain("SES");
  });

  it("given: London, should: leave out a slot below the horizon", () => {
    const labels = buildGeoOverlay(london).anchors.map((anchor) => anchor.label);
    expect(labels).not.toContain("129°W");
  });

  it("given: London, should: give every anchor a unique id", () => {
    const ids = buildGeoOverlay(london).anchors.map((anchor) => anchor.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("given: the equator, should: arch the belt through the zenith", () => {
    const { lines } = buildGeoOverlay({ latitudeDeg: 0, longitudeDeg: 30, altitudeM: 0 });
    let highest = 0;
    for (let offset = 1; offset < lines.length; offset += FLOATS_PER_VERTEX) {
      highest = Math.max(highest, lines[offset]);
    }
    expect(highest).toBeCloseTo(GEO_SHELL, 1);
  });

  it("given: the southern hemisphere, should: still draw an arc across the sky", () => {
    const { lines, anchors } = buildGeoOverlay({
      latitudeDeg: -33.87,
      longitudeDeg: 151.21,
      altitudeM: 0,
    });
    expect(lines.length).toBeGreaterThan(0);
    expect(anchors.some((anchor) => anchor.label === "156°E")).toBe(true);
  });
});
