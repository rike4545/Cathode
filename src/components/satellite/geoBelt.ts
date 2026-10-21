// The geostationary arc and the TV-satellite slots that sit on it, as geometry
// for the sky scene.
//
// Pure data in and out, so it is checkable without a GL context. The scene owns
// the buffers and the draw call; this decides where everything goes.
//
// A Starlink dish tracks a moving constellation, but a TV dish aims at one fixed
// point. Every such point lies on a single arc across the southern sky (northern
// sky in the southern hemisphere): the geostationary belt. Drawing the arc and
// its common slots on the same dome shows both kinds of satellite from one spot.

import { GEO_SATELLITES, formatOrbitalLongitude } from "@core/geoCatalog";
import { geoLookAngles, type GeoObserver } from "@core/geoLook";

/** Radius of the geostationary shell. The dome's dots sit at 1 and the Starlink
 *  constellation is pushed out beyond 2, so the arc reads as in between. */
export const GEO_SHELL = 1.6;

/** Elevation floor for drawing: a degree up keeps the arc clear of the ground ridges. */
const DRAW_FLOOR_DEG = 1;
/** Orbital longitude step along the arc. One degree is smooth at any zoom. */
const BELT_STEP_DEG = 1;
/** Half-length of a slot marker's cross, as a fraction of the shell radius. */
const MARKER_SIZE = 0.035;

const BELT_COLOR = [0.17, 0.75, 0.5] as const;
const MARKER_COLOR = [0.55, 1, 0.8] as const;

export interface GeoAnchor {
  /** Tracker name for the scene: "geo:" + id. */
  id: string;
  /** Short text for the on-screen tag, e.g. "28.2°E". */
  label: string;
  /** Longer description for a tooltip, e.g. "Astra 2 (Sky UK, Freesat) · SES". */
  title: string;
  /** Scene position of the slot. */
  position: [number, number, number];
}

export interface GeoOverlay {
  /** Line-list vertices: x, y, z, r, g, b per vertex, two vertices per segment. */
  lines: Float32Array;
  anchors: GeoAnchor[];
}

/** Scene axes are x east, y up, z south; azimuth is clockwise from north. */
export function skyDirectionToWorld(
  azimuthDeg: number,
  elevationDeg: number,
  radius: number,
): [number, number, number] {
  const azimuth = (azimuthDeg * Math.PI) / 180;
  const elevation = (elevationDeg * Math.PI) / 180;
  return [
    Math.cos(elevation) * Math.sin(azimuth) * radius,
    Math.sin(elevation) * radius,
    -Math.cos(elevation) * Math.cos(azimuth) * radius,
  ];
}

export function buildGeoOverlay(observer: GeoObserver): GeoOverlay {
  const vertices: number[] = [];
  const pushVertex = (point: readonly number[], colour: readonly number[]) =>
    vertices.push(point[0], point[1], point[2], colour[0], colour[1], colour[2]);

  // The arc: consecutive one-degree steps in orbital longitude, joined wherever
  // both ends are above the draw floor. A gap simply means that stretch of the
  // belt is below the horizon.
  let previous: [number, number, number] | null = null;
  for (let longitude = -180; longitude <= 180; longitude += BELT_STEP_DEG) {
    const look = geoLookAngles(observer, longitude);
    if (look.elevationDeg < DRAW_FLOOR_DEG) {
      previous = null;
      continue;
    }
    const point = skyDirectionToWorld(look.azimuthDeg, look.elevationDeg, GEO_SHELL);
    if (previous) {
      pushVertex(previous, BELT_COLOR);
      pushVertex(point, BELT_COLOR);
    }
    previous = point;
  }

  const anchors: GeoAnchor[] = [];
  for (const satellite of GEO_SATELLITES) {
    const look = geoLookAngles(observer, satellite.longitudeDeg);
    if (look.elevationDeg < DRAW_FLOOR_DEG) continue;
    const position = skyDirectionToWorld(look.azimuthDeg, look.elevationDeg, GEO_SHELL);

    // A small cross lying in the plane perpendicular to the line of sight, so it
    // faces the dome's centre whichever way the camera turns.
    const normal = position.map((component) => component / GEO_SHELL);
    const reference = Math.abs(normal[1]) > 0.98 ? [1, 0, 0] : [0, 1, 0];
    const right = normalise(crossProduct(normal, reference));
    const upAcross = crossProduct(right, normal);
    const reach = MARKER_SIZE * GEO_SHELL;
    for (const axis of [right, upAcross]) {
      pushVertex(
        [
          position[0] - axis[0] * reach,
          position[1] - axis[1] * reach,
          position[2] - axis[2] * reach,
        ],
        MARKER_COLOR,
      );
      pushVertex(
        [
          position[0] + axis[0] * reach,
          position[1] + axis[1] * reach,
          position[2] + axis[2] * reach,
        ],
        MARKER_COLOR,
      );
    }

    anchors.push({
      id: `${satellite.name}@${satellite.longitudeDeg}`,
      label: formatOrbitalLongitude(satellite.longitudeDeg),
      title: `${satellite.name} · ${satellite.operator}`,
      position,
    });
  }

  return { lines: new Float32Array(vertices), anchors };
}

function crossProduct(a: readonly number[], b: readonly number[]): [number, number, number] {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
}

function normalise(a: readonly number[]): [number, number, number] {
  const length = Math.hypot(a[0], a[1], a[2]) || 1;
  return [a[0] / length, a[1] / length, a[2] / length];
}
