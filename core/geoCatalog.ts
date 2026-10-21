// Popular geostationary TV and data positions, for the satellite finder.
//
// Orbital slots are stable for decades, but operators retire and swap
// spacecraft, so the names are hints about who usually broadcasts from a slot,
// not a promise about what is up there today. Anyone can aim at an arbitrary
// longitude instead.

import { geoLookAngles, type GeoLookAngles, type GeoObserver } from "./geoLook";

export interface GeoSatellite {
  name: string;
  /** Degrees, positive east / negative west. */
  longitudeDeg: number;
  operator: string;
  region: string;
}

export const GEO_SATELLITES: readonly GeoSatellite[] = [
  { name: "Dish", longitudeDeg: -129, operator: "Dish Network", region: "North America" },
  { name: "Dish", longitudeDeg: -119, operator: "Dish Network", region: "North America" },
  { name: "Dish", longitudeDeg: -110, operator: "Dish Network", region: "North America" },
  { name: "AMC-18", longitudeDeg: -105, operator: "SES", region: "North America" },
  { name: "DirecTV", longitudeDeg: -103, operator: "DirecTV", region: "North America" },
  { name: "DirecTV", longitudeDeg: -101, operator: "DirecTV", region: "North America" },
  { name: "DirecTV", longitudeDeg: -99, operator: "DirecTV", region: "North America" },
  { name: "Galaxy 19", longitudeDeg: -97, operator: "Intelsat", region: "North America" },
  { name: "Amazonas", longitudeDeg: -61, operator: "Hispasat", region: "South America" },
  { name: "Intelsat 21", longitudeDeg: -58, operator: "Intelsat", region: "South America" },
  { name: "Hispasat 30W", longitudeDeg: -30, operator: "Hispasat", region: "Atlantic" },
  { name: "Intelsat 907", longitudeDeg: -27.5, operator: "Intelsat", region: "Atlantic" },
  { name: "Eutelsat 7 West A", longitudeDeg: -7, operator: "Eutelsat", region: "Europe / MENA" },
  { name: "Nilesat", longitudeDeg: -7, operator: "Nilesat", region: "Middle East / North Africa" },
  { name: "Eutelsat 5 West", longitudeDeg: -5, operator: "Eutelsat", region: "Europe" },
  { name: "Thor", longitudeDeg: -0.8, operator: "Space Norway", region: "Europe" },
  { name: "Eutelsat 9B", longitudeDeg: 9, operator: "Eutelsat", region: "Europe" },
  { name: "Hot Bird", longitudeDeg: 13, operator: "Eutelsat", region: "Europe" },
  { name: "Eutelsat 16A", longitudeDeg: 16, operator: "Eutelsat", region: "Europe" },
  { name: "Astra 1", longitudeDeg: 19.2, operator: "SES", region: "Europe" },
  { name: "Astra 3", longitudeDeg: 23.5, operator: "SES", region: "Europe" },
  { name: "Arabsat / Badr", longitudeDeg: 26, operator: "Arabsat", region: "Middle East" },
  {
    name: "Astra 2 (Sky UK, Freesat)",
    longitudeDeg: 28.2,
    operator: "SES",
    region: "UK & Ireland",
  },
  { name: "Astra 5", longitudeDeg: 31.5, operator: "SES", region: "Europe" },
  { name: "Eutelsat 36B", longitudeDeg: 36, operator: "Eutelsat", region: "Russia / Africa" },
  { name: "Hellas Sat", longitudeDeg: 39, operator: "Hellas Sat", region: "Europe / Middle East" },
  { name: "Türksat", longitudeDeg: 42, operator: "Türksat", region: "Turkey / Middle East" },
  { name: "Yahsat", longitudeDeg: 52.5, operator: "Yahsat", region: "Middle East" },
  { name: "Intelsat 20", longitudeDeg: 68.5, operator: "Intelsat", region: "Africa / Asia" },
  { name: "Thaicom", longitudeDeg: 78.5, operator: "Thaicom", region: "Asia" },
  { name: "INSAT / GSAT", longitudeDeg: 83, operator: "ISRO", region: "India" },
  { name: "Measat 3", longitudeDeg: 91.5, operator: "Measat", region: "Asia" },
  { name: "AsiaSat 5", longitudeDeg: 100.5, operator: "AsiaSat", region: "Asia" },
  { name: "JCSAT-4B", longitudeDeg: 124, operator: "SKY Perfect JSAT", region: "Japan" },
  { name: "Optus", longitudeDeg: 156, operator: "Optus", region: "Australia" },
  { name: "Optus", longitudeDeg: 160, operator: "Optus", region: "Australia / New Zealand" },
  { name: "Intelsat 19", longitudeDeg: 166, operator: "Intelsat", region: "Pacific" },
];

/** "19.2°E", "119°W", "0°". */
export function formatOrbitalLongitude(longitudeDeg: number): string {
  const magnitude = Math.abs(longitudeDeg);
  const text = Number.isInteger(magnitude) ? String(magnitude) : magnitude.toFixed(1);
  if (magnitude === 0) return "0°";
  return `${text}°${longitudeDeg > 0 ? "E" : "W"}`;
}

export interface VisibleGeoSatellite {
  satellite: GeoSatellite;
  look: GeoLookAngles;
}

/** The catalogue above `minimumElevationDeg` from this spot, highest first. */
export function visibleGeoSatellites(
  observer: GeoObserver,
  minimumElevationDeg = 5,
): VisibleGeoSatellite[] {
  return GEO_SATELLITES.map((satellite) => ({
    satellite,
    look: geoLookAngles(observer, satellite.longitudeDeg),
  }))
    .filter(({ look }) => look.elevationDeg >= minimumElevationDeg)
    .sort((first, second) => second.look.elevationDeg - first.look.elevationDeg);
}
