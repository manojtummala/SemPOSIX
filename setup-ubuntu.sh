#!/usr/bin/env bash
# RAGFS build dependency installer for Ubuntu/Debian
# Run once: sudo ./setup-ubuntu.sh
set -euo pipefail

echo "Installing RAGFS build dependencies..."

apt-get update
apt-get install -y \
    build-essential \
    g++ \
    pkg-config \
    libssl-dev \
    libfuse-dev \
    protobuf-compiler \
    cmake \
    curl

echo "Done. Now run: cargo build --release"
