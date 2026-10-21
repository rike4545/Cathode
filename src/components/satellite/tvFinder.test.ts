import { describe, expect, it } from "vitest";
import {
  compassPoint,
  describeSkew,
  finderReadout,
  parseOffsetAngle,
  parseOrbitalLongitude,
} from "./tvFinder";

describe("parseOrbitalLongitude", () => {
  it("given: plain, lettered, degree-marked and decimal-comma forms, should: read them", () => {
    expect(parseOrbitalLongitude("19.2")).toBe(19.2);
    expect(parseOrbitalLongitude("19.2E")).toBe(19.2);
    expect(parseOrbitalLongitude("119W")).toBe(-119);
    expect(parseOrbitalLongitude("-101")).toBe(-101);
    expect(parseOrbitalLongitude(" 28.2 °e ")).toBe(28.2);
    expect(parseOrbitalLongitude("19,2")).toBe(19.2);
  });

  it("given: a minus sign and a hemisphere together, should: refuse rather than guess", () => {
    expect(parseOrbitalLongitude("-19E")).toBeNull();
    expect(parseOrbitalLongitude("-19W")).toBeNull();
  });

  it("given: nonsense or out-of-range text, should: return null", () => {
    expect(parseOrbitalLongitude("")).toBeNull();
    expect(parseOrbitalLongitude("astra")).toBeNull();
    expect(parseOrbitalLongitude("181")).toBeNull();
    expect(parseOrbitalLongitude("-181")).toBeNull();
    expect(parseOrbitalLongitude("19.2.3")).toBeNull();
  });

  it("given: the edges of the range, should: accept them", () => {
    expect(parseOrbitalLongitude("180")).toBe(180);
    expect(parseOrbitalLongitude("-180")).toBe(-180);
    expect(parseOrbitalLongitude("0")).toBe(0);
  });
});

describe("compassPoint", () => {
  it("given: cardinal and in-between bearings, should: name the nearest point", () => {
    expect(compassPoint(0)).toBe("N");
    expect(compassPoint(90)).toBe("E");
    expect(compassPoint(155.8)).toBe("SSE");
    expect(compassPoint(180)).toBe("S");
    expect(compassPoint(270)).toBe("W");
  });

  it("given: a bearing just short of a full turn, should: round up to north", () => {
    expect(compassPoint(359)).toBe("N");
    expect(compassPoint(-1)).toBe("N");
  });
});

describe("describeSkew", () => {
  it("given: positive and negative skew, should: say which way to twist", () => {
    expect(describeSkew(14.88)).toBe("14.9° clockwise");
    expect(describeSkew(-14.88)).toBe("14.9° anticlockwise");
  });

  it("given: almost none, should: say none", () => {
    expect(describeSkew(0.02)).toBe("none");
    expect(describeSkew(-0.04)).toBe("none");
  });
});

describe("finderReadout", () => {
  const london = { latitudeDeg: 51.5074, longitudeDeg: -0.1278, altitudeM: 0 };

  it("given: London and Astra 28.2E, should: match the independent reference", () => {
    // 145.424° / 25.394° from the separate Python implementation of the same geometry.
    const readout = finderReadout(london, 28.2, 0);
    expect(readout.look.azimuthDeg).toBeCloseTo(145.424, 2);
    expect(readout.look.elevationDeg).toBeCloseTo(25.394, 2);
    expect(readout.compass).toBe("SE");
    expect(readout.aboveHorizon).toBe(true);
    expect(readout.faceElevationDeg).toBeNull();
  });

  it("given: an offset dish, should: report the face tilt below the satellite", () => {
    const readout = finderReadout(london, 28.2, 22.7);
    expect(readout.faceElevationDeg).toBeCloseTo(readout.look.elevationDeg - 22.7, 9);
  });

  it("given: a satellite below the horizon, should: say so", () => {
    expect(finderReadout(london, -129, 0).aboveHorizon).toBe(false);
  });
});

describe("parseOffsetAngle", () => {
  it("given: blank, should: mean a prime-focus dish", () => {
    expect(parseOffsetAngle("")).toBe(0);
    expect(parseOffsetAngle("  ")).toBe(0);
  });

  it("given: a typical offset, should: read it, comma or point", () => {
    expect(parseOffsetAngle("22.7")).toBe(22.7);
    expect(parseOffsetAngle("22,7")).toBe(22.7);
  });

  it("given: nonsense or an implausible angle, should: return null", () => {
    expect(parseOffsetAngle("abc")).toBeNull();
    expect(parseOffsetAngle("-3")).toBeNull();
    expect(parseOffsetAngle("55")).toBeNull();
  });
});
