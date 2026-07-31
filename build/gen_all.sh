#!/bin/bash
for m in Kalimdor Expansion01 Northrend; do
  echo "=== $m ==="
  python tools/build_navgrid.py "$m" --deploy 2>&1 | tail -3
done
