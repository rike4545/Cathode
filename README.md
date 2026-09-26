# <img src="docs/logo.svg" alt="" width="34" height="34" align="top"> Cathode

**A local-first Starlink companion for desktop and browser.**

[![CI](https://github.com/rike4545/Cathode/actions/workflows/ci.yml/badge.svg)](https://github.com/rike4545/Cathode/actions/workflows/ci.yml)
[![CodeQL](https://github.com/rike4545/Cathode/actions/workflows/codeql.yml/badge.svg)](https://github.com/rike4545/Cathode/actions/workflows/codeql.yml)
[![Downloads](https://img.shields.io/github/downloads/rike4545/Cathode/total.svg)](https://github.com/rike4545/Cathode/releases)
[![macOS](https://img.shields.io/badge/macOS-12%2B-black.svg)](https://github.com/rike4545/Cathode/releases/latest)
[![Windows](https://img.shields.io/badge/Windows-10%2B-0078D4.svg)](https://github.com/rike4545/Cathode/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Cathode monitors the performance, health, usage, obstruction data, power draw,
network clients, and events of a Starlink system directly from the local
network. It is designed to remain useful when the Internet connection itself is
having problems.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="landing/src/assets/shots/dashboard-dark.png">
  <img alt="Cathode dashboard showing Starlink throughput, latency, power, ping success, obstruction information, charts, and event history." src="landing/src/assets/shots/dashboard-light.png">
</picture>

> [!NOTE]
> Cathode is an independent fork of
> [Dishylink](https://github.com/DaveyHert/dishylink). The original project and
> its contributors remain credited under the MIT license. Cathode maintains its
> own builds, releases, security reporting, update channel, and ongoing changes.

Cathode is unofficial and is not affiliated with SpaceX or Starlink.

## Why Cathode

- **Local-first monitoring** — dish and router telemetry is read over your LAN.
- **Useful during outages** — history and diagnostics do not depend on a working
  Starlink Internet connection.
- **No Cathode telemetry service** — Cathode does not upload your local
  monitoring history to a Cathode-operated backend.
- **Optional Starlink account integration** — sign-in is only needed for
  supported account-backed information or controls.
- **Desktop + browser extension** — one codebase supports Electron and WXT
  extension builds.
- **Long-term history** — local recording turns the dish's short rolling history
  into day, week, and month views.
- **Network controls** — manage supported router settings and device rules while
  retaining safeguards against accidentally pausing the machine running Cathode.

## Download

Cathode releases are published on GitHub:

**[Download the latest Cathode release](https://github.com/rike4545/Cathode/releases/latest)**

| Platform | Package | Architecture |
| --- | --- | --- |
| macOS 12+ | DMG | Apple silicon (`arm64`) |
| macOS 12+ | DMG | Intel (`x64`) |
| Windows 10+ | EXE | `x64` |
| Windows 10+ | EXE | `arm64` |
| Chrome / Edge | ZIP | Browser extension |
| Firefox | ZIP | Browser extension |

Browser-extension archives produced by Cathode are attached to Cathode releases.
The upstream Dishylink store listings are separate from Cathode and are not
presented here as Cathode downloads.

### macOS security note

Cathode's current macOS packaging is **ad-hoc signed**, not Developer ID
notarized. macOS may therefore show additional security prompts for downloaded
builds. The project does not currently claim Apple notarization.

### Windows security note

Current Windows installers are unsigned, so Microsoft SmartScreen may show an
unknown-publisher warning on first install.

## Features

### Live dashboard

Cathode provides live Starlink system information including:

- downlink and uplink throughput
- POP ping latency
- ping-success percentage
- dish power draw
- obstruction fraction
- compact sparklines
- 15-minute, 1-hour, and 6-hour dashboard windows
- outage overlays and event history
- thermal events and device alerts

### Historical telemetry

The local recorder extends the short history retained by Starlink hardware:

- day, week, and month throughput history
- latency history with spikes preserved during downsampling
- energy and power history
- coverage-aware gaps rather than invented values
- per-device usage history
- outage and event history

### Obstruction and sky tools

- 123×123 obstruction/SNR map
- polar sky visualization
- obstruction time-lapse
- full-screen sky view
- satellite constellation visualization
- satellite pass details
- dish alignment and orientation instruments

### Network and device visibility

- connected-client list
- client throughput
- device naming
- vendor and device-type information
- last-seen state
- router radio temperatures
- router event log
- per-device usage
- Starlink billing-cycle usage when available

### Alerts

Cathode grades alerts by severity and can surface them through:

- the in-app alert center
- desktop notifications
- extension badge state
- recorded device/outage history

### Supported controls

Depending on Starlink hardware, firmware, host platform, and whether an optional
Starlink account is connected, Cathode can expose controls such as:

- snow-melt mode
- sleep schedule
- update/reboot window
- software-update deferral
- dish reboot
- router reboot
- stow / unstow on supported motorized hardware
- obstruction-map reset
- Wi-Fi SSID and band configuration
- mesh-node trust
- custom DNS
- router subnet/address settings
- bypass mode
- connected-device pause/unpause
- factory-reset flows
- diagnostic export

Cathode intentionally does **not** expose content-filtering writes because an
invalid configuration can make the Wi-Fi network unavailable until a physical
reset.

## Network rules

Cathode can apply rules to individual devices or groups of devices.

### Data limits

Create daily, weekly, monthly, custom, billing-cycle, or one-time allowances.
Group allowances can either be pooled or applied separately to each member.

### Schedules

Pause devices according to recurring time windows, including weekday/weekend
patterns and windows that cross midnight.

### Timers

Apply a temporary countdown rule for a limited period.

Rules integrate with Cathode's supported device-pause workflow and include
protection intended to prevent Cathode from pausing the machine on which it is
running.

## Privacy model

Cathode is designed around local collection.

### Stays local by default

The following are stored locally on the machine or browser profile running
Cathode:

- telemetry history
- outage history
- energy history
- device history
- network-rule state
- local preferences
- locally recorded diagnostics

Cathode does not require a Cathode account and does not operate a telemetry
backend for this data.

### Optional Starlink account connection

Connecting a Starlink account is opt-in. When connected, requests required for
account-backed information or controls are sent to Starlink. Authentication
state is retained locally by Cathode.

The application no longer depends on third-party web fonts at runtime; the UI
uses system font stacks so startup remains local and outage-friendly.

See [PRIVACY.md](PRIVACY.md) for the detailed data-handling policy.

## Architecture

Cathode ships three related products from one repository:

| Target | Stack | Purpose |
| --- | --- | --- |
| Web development harness | React + Vite | Local development and testing |
| Desktop | Electron + React | macOS and Windows application |
| Browser extension | WXT + React | Chrome, Edge, and Firefox builds |

Shared Starlink protocol, telemetry, alert, history, and network-rule logic lives
primarily under `core/`.

Important directories:

```text
core/       shared Starlink protocol and application logic
collector/  local history recorder / historian
electron/   Electron main process and preload bridge
extension/  browser-extension host integration
src/        React application
schema/     Starlink protobuf descriptor data
landing/    project website
scripts/    build, packaging, and diagnostic helpers
docs/       project documentation and assets
```

## How Cathode talks to Starlink hardware

The dish exposes APIs at `192.168.100.1`. Cathode uses the Starlink grpc-web
interface for application communication, with host-specific transport layers for
Electron, browser-extension, and development environments.

| Port | Protocol | Use |
| --- | --- | --- |
| 9200 | native gRPC / HTTP2 | reflection and development tooling |
| 9201 | grpc-web / HTTP1.1 | application communication |

Starlink's local interface has browser-origin and request-header restrictions.
Cathode's trusted host layers handle those transport requirements rather than
requiring the renderer to communicate directly across those boundaries.

The protobuf schema is based on descriptors obtained from Starlink hardware
rather than manually guessed field layouts.

To refresh the descriptor after a firmware change:

```bash
grpcurl -plaintext -protoset-out schema/dish.protoset \
  192.168.100.1:9200 describe SpaceX.API.Device.Device

cp schema/dish.protoset public/dish.protoset
```

See [LOCAL-API.md](LOCAL-API.md) for additional protocol notes.

## Development

### Requirements

- Node.js 22
- npm
- Starlink LAN access for live hardware data
- Chromium dependencies when running browser tests

Install dependencies:

```bash
npm ci
```

### Run the web development harness

```bash
npm run dev
```

The Vite development server runs on localhost and proxies the local Starlink
interfaces used during development.

### Run the desktop app

macOS / Linux development host:

```bash
npm run dev:electron
```

Windows:

```bash
npm run dev:electron:win
```

### Run the browser extension

```bash
npm run dev:extension
```

WXT writes development extension output under `.output/`.

## Validation

Before submitting changes, run:

```bash
npm run typecheck
npm run typecheck:extension
npm run lint
npm test
npm run build
npm run build:extension
npm run build:extension:firefox
```

Useful developer commands:

```bash
npm run test:watch
npm run lint:fix
npm run format
npm run format:check
npm run historian
```

CI independently checks TypeScript, linting, tests, formatting, and extension
builds. CodeQL performs automated JavaScript/TypeScript security analysis, and
Dependabot handles recurring dependency-update proposals.

## Packaging

macOS:

```bash
npm run pack:mac
```

Windows:

```bash
npm run pack:win
```

Browser extensions:

```bash
npm run build:extension
npm run build:extension:firefox
npm run build:extension:edge

npm run zip:extension
npm run zip:extension:firefox
npm run zip:extension:edge
```

## Desktop behavior

The desktop app:

- continues recording while its main window is closed
- exits only when the user explicitly quits the tray/menu-bar application
- can launch at login
- supports native notifications
- exposes live throughput in the macOS menu bar
- provides a draggable always-on-top throughput widget on Windows
- remembers window placement
- supports GitHub-hosted application updates

## Browser-extension behavior

The extension:

- opens Cathode as a dedicated dashboard window or browser tab
- records local history in IndexedDB
- uses extension alarms to continue periodic collection while the browser is
  running
- can show current alert severity/count in its toolbar badge
- builds separately for Chromium-family browsers and Firefox

Because extension capabilities differ from Electron, some controls that require
reliable identification of the host machine are intentionally unavailable from
the browser extension.

## Recorded history

Starlink hardware retains only limited local history. Cathode's historian under
`collector/` records append-only local samples so longer time ranges are based
on observed data rather than interpolation.

A fresh installation therefore begins with little or no historical data and
builds its history over time.

See [collector/README.md](collector/README.md) for recorder details and the
on-disk format.

## Security

Please do not report vulnerabilities through a public issue.

Use the repository's
[private vulnerability reporting](https://github.com/rike4545/Cathode/security/advisories/new)
flow and include:

- affected Cathode version
- operating system or browser
- reproduction steps
- expected behavior
- observed behavior

See [SECURITY.md](SECURITY.md) for scope and reporting guidance.

## Contributing

Issues and pull requests are welcome.

For code changes:

1. create a focused branch
2. keep changes scoped and testable
3. run the validation commands above
4. document behavior changes when appropriate
5. open a pull request against `master`

When changing Starlink protocol behavior, prefer evidence from observed hardware
or captured protocol data over assumptions.

## Attribution

Cathode is derived from
[DaveyHert/dishylink](https://github.com/DaveyHert/dishylink) and continues under
the MIT license.

Upstream project authors and contributors retain attribution for their work.
Cathode-specific changes, releases, issue tracking, and support belong to this
repository.

## License

Cathode is released under the [MIT License](LICENSE).

Starlink is a trademark of Space Exploration Technologies Corp. Cathode is an
unofficial independent project and is not endorsed by, sponsored by, or
affiliated with SpaceX.
