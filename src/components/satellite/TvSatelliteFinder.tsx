// The TV satellite finder: pick a geostationary satellite, read off the angles
// to set a dish by.
//
// It sits beside the arc the sky view draws, and reports which slot is picked so
// that tag can be picked out on the dome. Native form controls rather than the
// app's popover select: this panel floats over a full-screen WebGL canvas, and a
// portalled menu has no business fighting that for a stacking order.

import { useEffect, useId, useState } from "react";
import { visibleGeoSatellites, formatOrbitalLongitude } from "@core/geoCatalog";
import type { ObserverLocation } from "../../lib/satellites";
import { loadTvFinderPrefs, saveTvFinderPrefs, type TvFinderPrefs } from "../../lib/tvFinderPrefs";
import { describeSkew, finderReadout, parseOffsetAngle, parseOrbitalLongitude } from "./tvFinder";

const CUSTOM = "custom";

const field =
  "h-9 w-full min-w-0 rounded-md border border-[#8b97a82e] bg-black px-2.5 text-[13px] " +
  "text-[#e6ebf2] outline-none focus-visible:border-[#c7d0dc80] aria-invalid:border-[#f87171]";
const label = "text-[11.5px] font-medium text-muted-foreground";

interface TvSatelliteFinderProps {
  observer: ObserverLocation;
  /** The catalogue slot currently picked, or null for a custom longitude. */
  onSlotChange: (anchorId: string | null) => void;
}

export function TvSatelliteFinder({ observer, onSlotChange }: TvSatelliteFinderProps) {
  const [prefs, setPrefs] = useState<TvFinderPrefs>(loadTvFinderPrefs);
  const update = (patch: Partial<TvFinderPrefs>) =>
    setPrefs((current) => {
      const next = { ...current, ...patch };
      saveTvFinderPrefs(next);
      return next;
    });

  const selectId = useId();
  const customId = useId();
  const offsetId = useId();

  const { latitudeDeg, longitudeDeg, altitudeM } = observer;
  const visible = visibleGeoSatellites({ latitudeDeg, longitudeDeg, altitudeM }, 3).map(
    (entry) => ({
      ...entry,
      id: `${entry.satellite.name}@${entry.satellite.longitudeDeg}`,
    }),
  );

  // A remembered satellite that is no longer in view (the site moved) falls back
  // to the best one in view rather than leaving the finder pointing at nothing.
  const chosen =
    prefs.slotId === CUSTOM
      ? CUSTOM
      : visible.some((entry) => entry.id === prefs.slotId)
        ? (prefs.slotId as string)
        : (visible[0]?.id ?? CUSTOM);

  const slot = visible.find((entry) => entry.id === chosen);
  const customLongitude = parseOrbitalLongitude(prefs.customText);
  const targetLongitude =
    chosen === CUSTOM ? customLongitude : (slot?.satellite.longitudeDeg ?? null);
  const offsetAngle = parseOffsetAngle(prefs.offsetText);

  const pickedAnchor = chosen === CUSTOM ? null : chosen;
  useEffect(() => {
    onSlotChange(pickedAnchor);
    return () => onSlotChange(null);
  }, [onSlotChange, pickedAnchor]);

  const readout =
    targetLongitude === null
      ? null
      : finderReadout({ latitudeDeg, longitudeDeg, altitudeM }, targetLongitude, offsetAngle ?? 0);

  return (
    <section
      data-slot='tv-finder'
      className='pointer-events-auto flex flex-col gap-3 rounded-xl border border-[#28282896] bg-[#00000094] px-4 py-4'
    >
      <h2 className='m-0 text-[13px] font-semibold'>TV satellite finder</h2>

      <div className='flex flex-col gap-1.5'>
        <label htmlFor={selectId} className={label}>
          Satellite
        </label>
        <select
          id={selectId}
          className={field}
          value={chosen}
          onChange={(event) => update({ slotId: event.target.value })}
        >
          {visible.map((entry) => (
            <option key={entry.id} value={entry.id}>
              {entry.satellite.name} · {formatOrbitalLongitude(entry.satellite.longitudeDeg)} ·{" "}
              {Math.round(entry.look.elevationDeg)}° up
            </option>
          ))}
          <option value={CUSTOM}>Another longitude…</option>
        </select>
      </div>

      {chosen === CUSTOM && (
        <div className='flex flex-col gap-1.5'>
          <label htmlFor={customId} className={label}>
            Orbital longitude
          </label>
          <input
            id={customId}
            className={field}
            inputMode='decimal'
            placeholder='e.g. 19.2E or 101W'
            value={prefs.customText}
            aria-invalid={prefs.customText !== "" && customLongitude === null}
            onChange={(event) => update({ customText: event.target.value })}
          />
          {prefs.customText !== "" && customLongitude === null && (
            <span className='text-[11.5px] text-[#f87171]'>
              Enter a longitude like 19.2E, 119W or -101.
            </span>
          )}
        </div>
      )}

      <div className='flex flex-col gap-1.5'>
        <label htmlFor={offsetId} className={label}>
          Dish offset angle, if it has one (°)
        </label>
        <input
          id={offsetId}
          className={field}
          inputMode='decimal'
          placeholder='blank for a prime-focus dish'
          value={prefs.offsetText}
          aria-invalid={offsetAngle === null}
          onChange={(event) => update({ offsetText: event.target.value })}
        />
        {offsetAngle === null && (
          <span className='text-[11.5px] text-[#f87171]'>
            The offset angle is usually 20–25°, and is printed on the dish.
          </span>
        )}
      </div>

      {readout && (
        <>
          <dl className='m-0 grid grid-cols-2 gap-x-4 gap-y-2.5'>
            <Figure
              name='Azimuth'
              value={`${readout.look.azimuthDeg.toFixed(1)}° ${readout.compass}`}
            />
            <Figure name='Elevation' value={`${readout.look.elevationDeg.toFixed(1)}°`} />
            <Figure name='LNB skew' value={describeSkew(readout.look.skewDeg)} />
            {readout.faceElevationDeg !== null && (
              <Figure name='Dish face tilt' value={`${readout.faceElevationDeg.toFixed(1)}°`} />
            )}
          </dl>
          {!readout.aboveHorizon && (
            <p className='m-0 text-[11.5px] leading-relaxed text-[#f87171]'>
              This satellite is below your horizon from here, so a dish at this site cannot see it.
            </p>
          )}
        </>
      )}

      <p className='m-0 text-[11.5px] leading-relaxed text-[#8b97a8]'>
        Bearings are from true north, not magnetic north. Skew is the twist to give the LNB, as seen
        from behind the dish looking at the satellite. Finish by peaking the signal on your
        receiver's meter.
      </p>
    </section>
  );
}

function Figure({ name, value }: { name: string; value: string }) {
  return (
    <div>
      <dt className='text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground'>
        {name}
      </dt>
      <dd className='m-0 font-mono text-[15px] font-semibold tabular-nums'>{value}</dd>
    </div>
  );
}
