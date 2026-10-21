// React binding for the shared TV-satellites choice.

import { useSyncExternalStore } from "react";
import { subscribeTvSatellites, tvSatellitesEnabled } from "../lib/tvSatellites";

/** The live choice, re-rendering whenever anything changes it. */
export function useTvSatellites(): boolean {
  return useSyncExternalStore(subscribeTvSatellites, tvSatellitesEnabled, () => false);
}
