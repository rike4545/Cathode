// Where a geostationary satellite sits in an observer's sky: compass bearing,
// elevation, LNB polarisation skew and slant range.
//
// Pure maths, no DOM and no network, so it runs the same in the desktop app, the
// browser build and the extension, and is checkable against hand figures.
//
// The Earth is the WGS84 ellipsoid, not a sphere. The spherical shortcut is about
// 0.2° off at mid latitudes, which is a large share of a small dish's beamwidth.
// The satellite sits on the equatorial plane at the geostationary radius; the
// observer's frame uses the geodetic latitude, i.e. the ellipsoid normal, because
// that is what a spirit level and a plumb line follow.

/** Where the observer stands. Matches `ObserverLocation` in src/lib/satellites. */
export interface GeoObserver {
  latitudeDeg: number;
  longitudeDeg: number;
  /** Metres above the ellipsoid; 0 is a fine default for a sky view. */
  altitudeM: number;
}

export interface GeoLookAngles {
  /** True-north bearing to the satellite, [0, 360). */
  azimuthDeg: number;
  /** Geometric elevation above the local horizontal, with no refraction. */
  elevationDeg: number;
  /**
   * LNB polarisation skew in (-90, 90]. Positive = rotate clockwise as seen from
   * behind the dish, looking toward the satellite. An LNB is symmetric under a
   * half turn, so the range is folded into a quarter circle either way.
   */
  skewDeg: number;
  rangeKm: number;
}

const WGS84_A_KM = 6378.137;
const WGS84_F = 1 / 298.257223563;
const WGS84_E2 = WGS84_F * (2 - WGS84_F);

/** Geostationary orbit radius from Earth's centre, km. */
export const GEO_RADIUS_KM = 42164.17;

const toRad = (degrees: number) => (degrees * Math.PI) / 180;
const toDeg = (radians: number) => (radians * 180) / Math.PI;

/** Wrap to [0, 360). */
export function wrapDegrees360(degrees: number): number {
  // The outer % also folds a tiny negative input, which rounds up to exactly 360.
  return ((degrees % 360) + 360) % 360;
}

type Vec3 = readonly [number, number, number];
const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

export function geoLookAngles(observer: GeoObserver, satelliteLongitudeDeg: number): GeoLookAngles {
  const phi = toRad(observer.latitudeDeg);
  const lambda = toRad(observer.longitudeDeg);
  const satelliteLongitude = toRad(satelliteLongitudeDeg);
  const heightKm = observer.altitudeM / 1000;

  const primeVertical = WGS84_A_KM / Math.sqrt(1 - WGS84_E2 * Math.sin(phi) ** 2);
  const observerEcef: Vec3 = [
    (primeVertical + heightKm) * Math.cos(phi) * Math.cos(lambda),
    (primeVertical + heightKm) * Math.cos(phi) * Math.sin(lambda),
    (primeVertical * (1 - WGS84_E2) + heightKm) * Math.sin(phi),
  ];
  const toSatellite: Vec3 = [
    GEO_RADIUS_KM * Math.cos(satelliteLongitude) - observerEcef[0],
    GEO_RADIUS_KM * Math.sin(satelliteLongitude) - observerEcef[1],
    -observerEcef[2],
  ];

  const east: Vec3 = [-Math.sin(lambda), Math.cos(lambda), 0];
  const north: Vec3 = [
    -Math.sin(phi) * Math.cos(lambda),
    -Math.sin(phi) * Math.sin(lambda),
    Math.cos(phi),
  ];
  const up: Vec3 = [
    Math.cos(phi) * Math.cos(lambda),
    Math.cos(phi) * Math.sin(lambda),
    Math.sin(phi),
  ];

  const e = dot(toSatellite, east);
  const n = dot(toSatellite, north);
  const u = dot(toSatellite, up);
  const rangeKm = Math.hypot(e, n, u);

  // Skew: the angle between local "up" and the satellite's polar axis, both
  // projected onto the plane perpendicular to the line of sight. The sign is
  // taken from the triple product so it is defined by geometry, not by a table.
  const lineOfSight: Vec3 = [e / rangeKm, n / rangeKm, u / rangeKm];
  const project = (v: Vec3): Vec3 => {
    const along = dot(v, lineOfSight);
    return [
      v[0] - along * lineOfSight[0],
      v[1] - along * lineOfSight[1],
      v[2] - along * lineOfSight[2],
    ];
  };
  const projectedUp = project([0, 0, 1]);
  const projectedPolar = project([0, Math.cos(phi), Math.sin(phi)]);
  const crossProduct: Vec3 = [
    projectedUp[1] * projectedPolar[2] - projectedUp[2] * projectedPolar[1],
    projectedUp[2] * projectedPolar[0] - projectedUp[0] * projectedPolar[2],
    projectedUp[0] * projectedPolar[1] - projectedUp[1] * projectedPolar[0],
  ];
  let skewDeg = toDeg(Math.atan2(dot(crossProduct, lineOfSight), dot(projectedUp, projectedPolar)));
  if (skewDeg > 90) skewDeg -= 180;
  if (skewDeg <= -90) skewDeg += 180;

  return {
    azimuthDeg: wrapDegrees360(toDeg(Math.atan2(e, n))),
    elevationDeg: toDeg(Math.atan2(u, Math.hypot(e, n))),
    skewDeg,
    rangeKm,
  };
}

/**
 * Bennett's refraction correction, in degrees, for a geometric elevation. Under
 * 0.03° above 30°, so it only matters for low satellites.
 */
export function refractionDeg(geometricElevationDeg: number): number {
  if (geometricElevationDeg <= -1) return 0;
  return 1 / Math.tan(toRad(geometricElevationDeg + 7.31 / (geometricElevationDeg + 4.4))) / 60;
}

/**
 * Elevation to read off an offset dish's own scale. The feed axis sits
 * `offsetAngleDeg` above the face normal, so the face points that much lower
 * than the satellite. A prime-focus dish has an offset of 0.
 */
export function offsetDishFaceElevationDeg(
  satelliteElevationDeg: number,
  offsetAngleDeg: number,
): number {
  return satelliteElevationDeg - offsetAngleDeg;
}
