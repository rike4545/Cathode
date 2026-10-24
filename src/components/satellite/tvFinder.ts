// The satellite finder's maths and wording, apart from the panel that shows it.
//
// What a person needs to aim a TV dish: the compass bearing, the elevation, how
// far to twist the LNB, and — for an offset dish — the tilt to read off the
// dish's own scale. Everything here is pure so it can be checked by hand.

import {
  geoLookAngles,
  offsetDishFaceElevationDeg,
  type GeoLookAngles,
  type GeoObserver,
} from "@core/geoLook";

/**
 * An orbital longitude as people write it: "19.2", "19.2E", "119W", "-119",
 * "19.2°E". A hemisphere letter and a minus sign together contradict each other
 * and are refused rather than guessed at.
 */
export function parseOrbitalLongitude(text: string): number | null {
  const match = /^\s*(-?\d+(?:[.,]\d+)?)\s*°?\s*([EeWw])?\s*$/.exec(text);
  if (!match) return null;
  const magnitude = Number(match[1].replace(",", "."));
  if (!Number.isFinite(magnitude)) return null;
  const hemisphere = match[2]?.toUpperCase();
  let longitude = magnitude;
  if (hemisphere) {
    if (magnitude < 0) return null;
    longitude = hemisphere === "W" ? -magnitude : magnitude;
  }
  return longitude >= -180 && longitude <= 180 ? longitude : null;
}

const COMPASS_POINTS = [
  "N",
  "NNE",
  "NE",
  "ENE",
  "E",
  "ESE",
  "SE",
  "SSE",
  "S",
  "SSW",
  "SW",
  "WSW",
  "W",
  "WNW",
  "NW",
  "NNW",
];

/** The nearest of the sixteen compass points, for a bearing in degrees. */
export function compassPoint(azimuthDeg: number): string {
  const index = Math.round((((azimuthDeg % 360) + 360) % 360) / 22.5) % 16;
  return COMPASS_POINTS[index];
}

/**
 * Which way to twist the LNB, in words. The sign convention is the one in
 * `GeoLookAngles`: clockwise as seen from behind the dish looking at the
 * satellite. Under a twentieth of a degree is no twist at all.
 */
export function describeSkew(skewDeg: number): string {
  if (Math.abs(skewDeg) < 0.05) return "none";
  return `${Math.abs(skewDeg).toFixed(1)}° ${skewDeg > 0 ? "clockwise" : "anticlockwise"}`;
}

export interface FinderReadout {
  look: GeoLookAngles;
  compass: string;
  aboveHorizon: boolean;
  /** Tilt to read off an offset dish's own scale; null for a prime-focus dish. */
  faceElevationDeg: number | null;
}

export function finderReadout(
  observer: GeoObserver,
  satelliteLongitudeDeg: number,
  offsetAngleDeg: number,
): FinderReadout {
  const look = geoLookAngles(observer, satelliteLongitudeDeg);
  return {
    look,
    compass: compassPoint(look.azimuthDeg),
    aboveHorizon: look.elevationDeg > 0,
    faceElevationDeg:
      offsetAngleDeg > 0 ? offsetDishFaceElevationDeg(look.elevationDeg, offsetAngleDeg) : null,
  };
}

/** An offset angle from a text box: blank is prime focus, and the plausible range is 0 to 40. */
export function parseOffsetAngle(text: string): number | null {
  if (text.trim() === "") return 0;
  const value = Number(text.trim().replace(",", "."));
  return Number.isFinite(value) && value >= 0 && value <= 40 ? value : null;
}
