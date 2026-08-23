# Cathode

A local-first instrument panel for your Starlink dish, for iPhone and iPad.

Cathode talks straight to the dish on your own network over its local gRPC API.
There is no account, no cloud service, and no telemetry — the app and the
hardware, nothing in between.

<p align="center">
  <img src="docs/screenshots/dashboard.png" width="270" alt="Dashboard showing health score, live throughput and stat tiles">
  <img src="docs/screenshots/sky.png" width="270" alt="Sky obstruction dome with placement advisor">
  <img src="docs/screenshots/history.png" width="270" alt="History screen with usage, availability and throughput charts">
</p>

---

## What it does

**Live telemetry.** Download and upload, latency to the point of presence,
packet loss, power draw, signal, obstruction, GPS and alignment — polled once a
second and drawn as a mirrored throughput ribbon with outage bands, so a gap
reads as *no data* rather than as zero.

**Sky obstruction map.** The dish's 123×123 SNR grid, rendered as a polar sky
dome with elevation rings, a compass, and a live scan sweep. The boresight
marker eases along each satellite pass and leaves a fading track behind it, so
you can see the arc of sky actually in use and count the handoffs — a terminal
switches satellites every fifteen seconds, and a single jumping dot shows none
of that.

**Placement advisor.** The dish reports *how much* sky is blocked but never
*where*. Cathode reduces the SNR grid into angular wedges, finds the worst ones,
and turns that into an instruction you can act on while standing outside:
which direction the blockage is, how high it reaches, which way to move, and
roughly how much of the problem that one direction accounts for.

**History that outlives the dish.** The dish keeps 12 hours in a ring buffer and
loses it on reboot. Cathode records what it sees into SQLite at two resolutions —
one row per second for 48 hours, one row per minute forever — so it can answer
questions the hardware cannot: what did last month look like, when do the outages
cluster, is the obstruction getting worse since the tree was trimmed.

**Availability and usage.** Uptime as a percentage with downtime accounted for,
data moved in each direction, energy consumed with a monthly projection, and an
optional allowance tracker on your billing cycle.

**Lost time, attributed.** Every dropped second is assigned a cause, because
"obstructed" and "the network had no slot to give you" look identical on a
throughput chart and have nothing in common. One is fixed with a chainsaw; the
other is Starlink capacity in your cell. Cathode is the only monitor that splits
them, and the totals reconcile exactly — obstructed plus no-capacity plus other
equals the seconds actually lost.

**95th-percentile latency.** The average hides exactly the spikes that break a
video call. p95 is what latency reaches in the worst second out of twenty, and
it is the number that predicts whether a connection *feels* good.

**Signal-to-noise history.** The dish has always sent a per-second SNR series
and most tools discard it. A broad SNR sag with no obstruction is rain or snow;
an obstruction cuts sharply and always in the same part of the sky. Together
they answer "is it the weather or is it my trees". Newer firmware leaves the
series at zero, in which case the chart is hidden rather than drawn empty.

**Usage by device, over time.** The router reports only a running lifetime total
per client, which answers the wrong question. Cathode samples those counters and
stores the differences, so it can rank who has actually been using the
connection today, this week, or this month — and it re-baselines rather than
recording nonsense when a router reboot resets the counters.

**Alerts that mean something.** The dish raises hardware alert bits, but most of
what actually degrades a connection never sets one. Cathode watches latency,
packet loss, obstruction, signal, throughput floor and stability, grades each
finding by severity, and — where there is something to do about it — says what.

**Speed test with a bufferbloat grade.** A speed number tells you how fast a
download finishes. It says nothing about whether a video call survives while that
download runs. Cathode measures latency under load and grades it A+ to F.

**Alerts that reach you.** Anything at or above your chosen severity arrives as
a local notification, deduplicated by alert so a flapping link cannot produce a
storm, and withdrawn automatically once the problem clears. A background task
keeps checking while the app is closed.

One honest limit, stated in Settings rather than buried: Cathode reads the dish
over the local network, so a background check only succeeds while the device is
actually on that network. Away from home you will not be alerted. There is no
cloud relay — which is the same reason there is no account.

**Controls.** Reboot, stow and unstow, reset the obstruction map, sleep schedule,
snow melt. Every mutating action confirms first.

**Diagnostics.** Connection and firmware detail, a capability probe that asks the
hardware which operations it actually implements, and a read-only request console
that dumps any response as an inspectable field tree.

**Accessible.** The sky dome is a rendered bitmap, so VoiceOver is given a
spoken summary of it instead — how much sky is blocked, where the dish is
pointing, how much of the dome has been surveyed. Stat tiles read as one
statement rather than four fragments, and sparklines announce their trend.

**Demo mode.** A full behavioural simulation of a terminal, so the app is
completely explorable with no hardware present. It is the default on first run,
and it never sends notifications — being woken at 2am by a simulated outage
would be a bug, not a feature.

---

## Requirements

- Xcode 16 or later (built and tested against Xcode 26.6 / Swift 6.3)
- iOS 18.0 or later
- For live data: an iPhone or iPad on the same network as the dish

## Build and run

```bash
open Cathode.xcodeproj
```

Select the **Cathode** scheme and run. The app opens in demo mode, so it works
immediately in the Simulator with nothing else set up.

To build from the command line:

```bash
xcodebuild -project Cathode.xcodeproj -scheme Cathode -destination 'platform=iOS Simulator,name=iPhone 17' build
```

To point it at real hardware, join the Starlink network and switch
**More → Connection → My Starlink**.

## Tests

The wire format and analysis layers have a dependency-free harness that compiles
the platform-independent core and runs it:

```bash
./Tests/run.sh
```

These cover the places where a mistake is invisible in the UI — a mis-decoded
array still draws a chart, it just draws the wrong one. Two real bugs were caught
this way and both are pinned by tests: packed-float element width, and rollup
double-counting when the dish's ring buffer is deliberately re-read.

---

## How it talks to the dish

The dish exposes a gRPC service, `SpaceX.API.Device.Device`, on the local
network. Every operation travels over a single method, `Handle`, as one arm of a
protobuf `oneof` — so the entire API surface reduces to `call(op:)`.

| Endpoint | Port | Protocol | Used by Cathode |
| --- | --- | --- | --- |
| `192.168.100.1` | 9200 | native gRPC over HTTP/2 | no — needs trailers `URLSession` does not expose |
| `192.168.100.1` | 9201 | gRPC-web over HTTP/1.1 | **yes** |
| `192.168.1.1` | 9000 | router, same service | yes, when present |

Cathode speaks gRPC-web over `URLSession`, which means **no gRPC library and no
protobuf toolchain** — the wire codec is about 450 lines of Swift in
`Core/Protobuf` and `Core/Grpc`. The whole app has zero third-party dependencies.

Two iOS specifics are handled in `Config/Info.plist`: the dish is HTTP-only, so
there is a scoped App Transport Security exception for its two addresses; and
reaching a LAN address triggers the local-network privacy prompt, which the app
explains and reports clearly if declined.

### On the undocumented API

Starlink's Device API is not publicly documented. The field numbers in
`Core/Starlink/DishSchema.swift` are the community-known layout used across the
open-source tooling ecosystem — a well-supported starting point, **not a
specification**, and not something this project can verify against every
firmware revision.

So Cathode is built to degrade honestly rather than to be confidently wrong:

- Responses are decoded **structurally**, by field number and wire type, instead
  of against a compiled schema. A firmware update that adds fields does not break
  parsing, and a field that cannot be found reads as *unknown* rather than as a
  plausible wrong number.
- Every optional value stays optional all the way to the view. A dish that does
  not report power shows `—`, never `0 W`.
- **Diagnostics → Supported operations** probes the hardware and reports which
  operations it actually answers, so an operation whose number has moved shows up
  as unsupported instead of as bad data.
- Packed array element width comes from the schema, never from sniffing the
  bytes. (This was a real bug: 43 200 float32s is also a valid byte length for
  float64s, and adjacent watt values reinterpret into plausible-looking doubles
  around 1e12.)

If you have hardware and something decodes wrong, the request console in
Diagnostics dumps the raw field tree — that output is the useful thing to report.

---

## Architecture

```
Cathode/
├── Core/                     no UIKit, no SwiftUI — fully testable
│   ├── Protobuf/             wire-format reader and writer
│   ├── Grpc/                 framing, transport protocol, gRPC-web over URLSession
│   ├── Starlink/             types, field map, decoders, client actor
│   ├── Sim/                  behavioural dish model + a transport that encodes it
│   ├── Store/                SQLite history with two-tier rollups
│   └── Analytics/            alert engine, grading, obstruction advisor, trends
├── DesignSystem/             palette, type scale, shared components, formatters
├── App/                      entry point, app model, settings, poll loop,
│                             notifications, background refresh
├── Features/                 one folder per screen
└── Config/Info.plist
```

`DishTransport` is the seam. Both the real gRPC-web transport and the simulator
conform to it, so nothing above that layer knows which one it is talking to.

**The simulator encodes real protobuf.** It would have been easier to return
typed values directly, but then demo mode would exercise none of the framing,
field numbering or decode logic. Instead it produces the same bytes hardware
would, so a bug in the wire layer surfaces in the Simulator instead of hiding
until someone plugs in a dish. Both bugs found during development were caught
this way.

The model itself is behavioural, not a random walk: satellite handoffs land on
15-second boundaries with a latency step, obstructions are fixed objects in the
sky that only bite when the tracked satellite passes behind one, household demand
follows a diurnal curve with bursty streaming, rain fade degrades SNR and
throughput together, and power tracks load plus a heater draw when it is cold.

**One poll loop drives everything.** Status is read every second; the obstruction
map, router client list and location are on their own slower cadences so a
15 129-cell SNR grid never blocks the live numbers.

35 Swift files, ~8 000 lines, of which ~3 400 are the platform-independent core.

---

## Privacy

Cathode reads from your dish and writes to your device. That is the whole data
flow.

- No account, no sign-in, no server.
- No analytics, crash reporting, or telemetry of any kind.
- History lives in the app's own container and is deleted with the app. You can
  erase it at any time from **More → Recorded history**.
- The only network destinations the app ever contacts are the two local addresses
  in the table above.

---

## Relationship to Dishylink

Cathode began as an iOS answer to [Dishylink](https://github.com/DaveyHert/Dishylink),
an open-source Starlink monitor for desktop and browsers, and covers the same
ground: live stat tiles, throughput and latency and power charts, the sky
obstruction dome, alignment, device usage, event logs, speed tests and alerts,
and the dish and router controls.

What Cathode adds on top:

- **Native iOS** rather than Electron and a browser extension.
- **History beyond the session** — SQLite with minute rollups kept indefinitely,
  instead of charts limited to 15 m / 1 h / 6 h.
- **Availability and energy reporting** — uptime percentage, downtime accounting,
  kWh with a monthly projection, allowance tracking against a billing cycle.
- **The placement advisor** — not just how much sky is blocked, but which
  direction, how high, and what to do.
- **Bufferbloat grading** on speed tests, and a rolling connection grade from
  history.
- **Trend and hour-of-day analysis** — what changed against a longer baseline,
  and which hours are consistently worst.
- **An alert engine with editable thresholds** and remedies, rather than only
  passing through the dish's own alert bits — plus notifications and background
  checks, so a problem finds you instead of waiting to be noticed.
- **A capability probe and request console**, so an undocumented API is
  inspectable rather than opaque.
- **Zero dependencies** — no protobuf runtime, no gRPC library, no chart library
  beyond Apple's own.

## License

MIT.

Not affiliated with, endorsed by, or sponsored by SpaceX or Starlink. Starlink is
a trademark of Space Exploration Technologies Corp.
