import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { cleanup, render } from "vitest-browser-react";
import { page } from "vitest/browser";
import { finderReadout } from "./tvFinder";
import { TvSatelliteFinder } from "./TvSatelliteFinder";

const london = { latitudeDeg: 51.5074, longitudeDeg: -0.1278, altitudeM: 0 };

beforeEach(() => localStorage.clear());
afterEach(cleanup);

const settle = () => new Promise((resolve) => setTimeout(resolve, 30));
const text = () => document.body.textContent ?? "";

/** The finder's own figures, e.g. "155.8° SSE". */
const azimuthFor = (longitude: number, offset = 0) => {
  const { look, compass } = finderReadout(london, longitude, offset);
  return `${look.azimuthDeg.toFixed(1)}° ${compass}`;
};

test("it opens on the best satellite in view and shows its angles", async () => {
  const onSlotChange = vi.fn();
  render(<TvSatelliteFinder observer={london} onSlotChange={onSlotChange} />);
  await settle();

  expect(text()).toContain("Azimuth");
  expect(text()).toContain("Elevation");
  expect(text()).toContain("LNB skew");
  // No offset entered, so no offset-dish figure.
  expect(text()).not.toContain("Dish face tilt");
  expect(onSlotChange).toHaveBeenLastCalledWith(expect.stringContaining("@"));
});

test("picking a satellite shows its bearing and reports the slot", async () => {
  const onSlotChange = vi.fn();
  render(<TvSatelliteFinder observer={london} onSlotChange={onSlotChange} />);
  await page.getByLabelText("Satellite").selectOptions("Hot Bird@13");
  await settle();

  expect(text()).toContain(azimuthFor(13));
  expect(onSlotChange).toHaveBeenLastCalledWith("Hot Bird@13");
});

test("a typed longitude is read, and nothing is reported for the dome", async () => {
  const onSlotChange = vi.fn();
  render(<TvSatelliteFinder observer={london} onSlotChange={onSlotChange} />);
  await page.getByLabelText("Satellite").selectOptions("custom");
  await page.getByLabelText("Orbital longitude").fill("19.2E");
  await settle();

  expect(text()).toContain(azimuthFor(19.2));
  expect(onSlotChange).toHaveBeenLastCalledWith(null);
});

test("an unreadable longitude says so and shows no angles", async () => {
  render(<TvSatelliteFinder observer={london} onSlotChange={() => {}} />);
  await page.getByLabelText("Satellite").selectOptions("custom");
  await page.getByLabelText("Orbital longitude").fill("astra");
  await settle();

  expect(text()).toContain("Enter a longitude like");
  expect(text()).not.toContain("LNB skew");
});

test("an offset angle adds the dish face tilt, and a silly one is flagged", async () => {
  render(<TvSatelliteFinder observer={london} onSlotChange={() => {}} />);
  await page.getByLabelText("Satellite").selectOptions("Hot Bird@13");
  await page.getByLabelText(/Dish offset angle/).fill("22.7");
  await settle();

  expect(text()).toContain("Dish face tilt");
  const expected = finderReadout(london, 13, 22.7).faceElevationDeg!.toFixed(1);
  expect(text()).toContain(`${expected}°`);

  await page.getByLabelText(/Dish offset angle/).fill("90");
  await settle();
  expect(text()).toContain("usually 20–25°");
});

test("a satellite below the horizon is called out", async () => {
  render(<TvSatelliteFinder observer={london} onSlotChange={() => {}} />);
  await page.getByLabelText("Satellite").selectOptions("custom");
  await page.getByLabelText("Orbital longitude").fill("129W");
  await settle();

  expect(text()).toContain("below your horizon");
});

test("choices are remembered the next time it opens", async () => {
  const first = await render(<TvSatelliteFinder observer={london} onSlotChange={() => {}} />);
  await page.getByLabelText("Satellite").selectOptions("Hot Bird@13");
  await page.getByLabelText(/Dish offset angle/).fill("22.7");
  await settle();
  await first.unmount();

  await render(<TvSatelliteFinder observer={london} onSlotChange={() => {}} />);
  await settle();
  expect(text()).toContain(azimuthFor(13));
  expect((page.getByLabelText(/Dish offset angle/).element() as HTMLInputElement).value).toBe(
    "22.7",
  );
});
