#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || cp .env.example .env
[[ -d node_modules ]] || npm ci
npm run doctor
npm start
