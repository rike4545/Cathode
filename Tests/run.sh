#!/bin/bash
# Compiles Cathode's platform-independent core and runs the test harness.
# The UI layers need UIKit, so they are excluded; everything below the views is
# plain Foundation and covered here.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(
  Cathode/Core/Protobuf/ProtoReader.swift
  Cathode/Core/Protobuf/ProtoWriter.swift
  Cathode/Core/Grpc/GrpcFrame.swift
  Cathode/Core/Grpc/Transport.swift
  Cathode/Core/Starlink/DishTypes.swift
  Cathode/Core/Starlink/DishSchema.swift
  Cathode/Core/Starlink/DishDecode.swift
  Cathode/Core/Starlink/DishClient.swift
  Cathode/Core/Sim/DishSimulator.swift
  Cathode/Core/Sim/SimulatorTransport.swift
  Cathode/Core/Store/HistoryStore.swift
  Cathode/Core/Analytics/Alerts.swift
  Cathode/Core/Analytics/Insights.swift
  Cathode/DesignSystem/Format.swift
  Tests/CoreTests.swift
)

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -swift-version 6 -parse-as-library \
  -O -o "$OUT/coretests" "${SOURCES[@]}" 2>&1 | grep -v "^$" || true

if [ ! -x "$OUT/coretests" ]; then
  echo "compilation failed"
  exit 1
fi
"$OUT/coretests"
