#!/bin/sh

REPO_DIR="${REPO_DIR:-/home/dac/free-sleep}"

python3 "$REPO_DIR/scripts/is_biometrics_installed.py"
result=$?
biometrics_installed=false

if [ $result -eq 0 ]; then
  echo "Biometrics environment not setup, continuing with installation..."
elif [ $result -eq 1 ]; then
  echo "Biometrics is already installed; refreshing dependencies and enabling the streamer..."
  biometrics_installed=true
else
  echo "Unable to check if biometrics installed, exiting..."
  exit 1
fi

set -eu

RED='\033[0;31m'
NC='\033[0m' # No Color

firewall_restored=false

# Single exit path for success, failures, and termination signals.
cleanup() {
  exit_status=$?
  trap - INT TERM HUP
  set +e
  if [ "$exit_status" -ne 0 ]; then
    echo ""
    printf "%b\n" "${RED}Error enabling biometrics! Exit code $exit_status${NC}" >&2
    echo ""
    curl -fsS --max-time 10 -X POST http://127.0.0.1:3000/api/services \
      -H "Content-Type: application/json" \
      -d '{
        "biometrics": {
          "jobs": {
            "installation": {
              "status": "failed"
            }
          }
        }
      }' >/dev/null 2>&1 || true
  fi

  if [ "$firewall_restored" != "true" ]; then
    firewall_restored=true
    sh "$REPO_DIR/scripts/block_internet_access.sh" --restore-prior-state || {
      echo "ERROR: Failed to restore firewall state" >&2
      if [ "$exit_status" -eq 0 ]; then
        exit_status=1
      fi
    }
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Temporarily unblock internet for package downloads; cleanup restores the saved preference.
sh "$REPO_DIR/scripts/unblock_internet_access.sh"

if [ "$biometrics_installed" = false ] || [ ! -x /home/dac/venv/bin/python ]; then
  sh "$REPO_DIR/scripts/setup_python.sh"
fi
sh "$REPO_DIR/scripts/install_python_packages.sh"
sh "$REPO_DIR/scripts/setup_streamer_service.sh"

# Mark the installation status as healthy with bounded timeout and failure checking
curl -fsS --max-time 10 -X POST http://127.0.0.1:3000/api/services \
  -H "Content-Type: application/json" \
  -d '{
    "biometrics": {
      "jobs": {
        "installation": {
          "status": "healthy"
        }
      }
    }
  }'

# Restore prior firewall state now that network downloads are complete
firewall_restored=true
sh "$REPO_DIR/scripts/block_internet_access.sh" --restore-prior-state

if [ "$biometrics_installed" = false ]; then
  cd "$REPO_DIR/biometrics/sleep_detection" && /home/dac/venv/bin/python calibrate_sensor_thresholds.py
fi
