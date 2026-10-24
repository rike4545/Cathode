// Where the sun is, from the NOAA solar position algorithm (about 0.01° for
// current dates). The sun is the one absolute, magnet-free bearing a phone owner
// can check, so the satellite finder uses it to measure compass error.

export interface SunPosition {
  /** True-north bearing, [0, 360). */
  azimuthDeg: number;
  /** Geometric elevation above the horizon. */
  elevationDeg: number;
}

const toRad = (degrees: number) => (degrees * Math.PI) / 180;
const toDeg = (radians: number) => (radians * 180) / Math.PI;
const wrap360 = (degrees: number) => ((degrees % 360) + 360) % 360;

export function sunPosition(at: Date, latitudeDeg: number, longitudeDeg: number): SunPosition {
  const unixSeconds = at.getTime() / 1000;
  const julianDay = unixSeconds / 86400 + 2440587.5;
  const t = (julianDay - 2451545.0) / 36525;

  const meanLongitude = wrap360(280.46646 + t * (36000.76983 + t * 0.0003032));
  const meanAnomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t);
  const eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
  const m = toRad(meanAnomaly);
  const equationOfCentre =
    Math.sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
    Math.sin(2 * m) * (0.019993 - 0.000101 * t) +
    Math.sin(3 * m) * 0.000289;
  const trueLongitude = meanLongitude + equationOfCentre;
  const omega = 125.04 - 1934.136 * t;
  const apparentLongitude = trueLongitude - 0.00569 - 0.00478 * Math.sin(toRad(omega));
  const meanObliquity =
    23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60;
  const obliquity = meanObliquity + 0.00256 * Math.cos(toRad(omega));
  const declination = Math.asin(Math.sin(toRad(obliquity)) * Math.sin(toRad(apparentLongitude)));

  const y = Math.tan(toRad(obliquity / 2)) ** 2;
  const l0 = toRad(meanLongitude);
  const equationOfTimeMinutes =
    4 *
    toDeg(
      y * Math.sin(2 * l0) -
        2 * eccentricity * Math.sin(m) +
        4 * eccentricity * y * Math.sin(m) * Math.cos(2 * l0) -
        0.5 * y * y * Math.sin(4 * l0) -
        1.25 * eccentricity * eccentricity * Math.sin(2 * m),
    );

  const utcMinutes = (((unixSeconds % 86400) + 86400) % 86400) / 60;
  const trueSolarMinutes =
    (((utcMinutes + equationOfTimeMinutes + 4 * longitudeDeg) % 1440) + 1440) % 1440;
  let hourAngle = trueSolarMinutes / 4 - 180;
  if (hourAngle < -180) hourAngle += 360;

  const phi = toRad(latitudeDeg);
  const hourAngleRad = toRad(hourAngle);
  const cosZenith =
    Math.sin(phi) * Math.sin(declination) +
    Math.cos(phi) * Math.cos(declination) * Math.cos(hourAngleRad);
  const zenith = Math.acos(Math.max(-1, Math.min(1, cosZenith)));
  const azimuth =
    toDeg(
      Math.atan2(
        Math.sin(hourAngleRad),
        Math.cos(hourAngleRad) * Math.sin(phi) - Math.tan(declination) * Math.cos(phi),
      ),
    ) + 180;

  return { azimuthDeg: wrap360(azimuth), elevationDeg: 90 - toDeg(zenith) };
}
