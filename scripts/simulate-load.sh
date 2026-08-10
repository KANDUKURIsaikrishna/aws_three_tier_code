#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# simulate-load.sh
#
# On-demand load simulation to trigger the HighPodCPUUsage / HighRequestRate
# alerts for a demo. Two independent simulations, run either or both:
#   - CPU:     a throwaway `polinux/stress` pod in the `default` namespace
#              (no NetworkPolicy concerns, cAdvisor picks up any pod on the
#              node regardless of namespace or annotations)
#   - traffic: a sustained curl loop against the real ingress ELB, HTTPS
#              (plain HTTP gets redirected at the nginx layer itself before
#              ever reaching api-gateway -- see TROUBLESHOOTING.md OBS-048)
#
# Always cleans up after itself (stress pod deleted, load loop killed) via a
# trap, even on Ctrl-C or an error partway through.
#
# Usage:
#   ./scripts/simulate-load.sh                     # both, 3 minutes
#   ./scripts/simulate-load.sh --cpu-only
#   ./scripts/simulate-load.sh --traffic-only
#   ./scripts/simulate-load.sh --duration 300       # seconds
#   ./scripts/simulate-load.sh --rps 30             # requests/sec target
#
# Requires: kubectl (pointed at the right cluster), curl, aws CLI, jq.
# Prints the current firing alerts (from Prometheus) once the simulation
# starts, so you can watch them appear without opening a browser.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOMAIN="api.bookstore.b17facebook.xyz"
DURATION=180
RPS=20
DO_CPU=true
DO_TRAFFIC=true
STRESS_POD="cpu-stress-demo"
LOAD_LOG="/tmp/simulate-load-$$.log"
LOAD_PID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cpu-only)      DO_TRAFFIC=false ;;
    --traffic-only)  DO_CPU=false ;;
    --duration)      DURATION="$2"; shift ;;
    --rps)           RPS="$2"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

cleanup() {
  echo
  echo "── Cleaning up ──────────────────────────────────────────────────────"
  if [ -n "$LOAD_PID" ] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
    wait "$LOAD_PID" 2>/dev/null || true
    echo "Stopped load generator (pid $LOAD_PID)."
  fi
  if kubectl get pod "$STRESS_POD" -n default >/dev/null 2>&1; then
    kubectl delete pod "$STRESS_POD" -n default --wait=false >/dev/null 2>&1 || true
    echo "Deleted $STRESS_POD."
  fi
  rm -f "$LOAD_LOG"
}
trap cleanup EXIT INT TERM

MONITORING_IP=$(terraform output -raw prometheus_url 2>/dev/null | sed 's|http://||' | cut -d: -f1)
if [ -z "$MONITORING_IP" ]; then
  echo "Couldn't read prometheus_url from terraform output -- run this from the repo root with the stack applied." >&2
  exit 1
fi

if [ "$DO_CPU" = true ]; then
  echo "── Starting CPU stress pod (2 cores, ${DURATION}s) ──────────────────"
  kubectl delete pod "$STRESS_POD" -n default --ignore-not-found=true --wait=true >/dev/null 2>&1
  kubectl run "$STRESS_POD" --image=polinux/stress --restart=Never --namespace=default \
    -- stress --cpu 2 --timeout "${DURATION}s" >/dev/null
  echo "Started. Watch: kubectl top pod $STRESS_POD -n default"
fi

if [ "$DO_TRAFFIC" = true ]; then
  echo "── Starting traffic load (~${RPS} req/s against https://$DOMAIN/books, ${DURATION}s) ──"
  ELB=$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[0].DNSName' --output text)
  SLEEP=$(python3 -c "print(1/$RPS)")
  (
    END=$((SECONDS + DURATION))
    while [ $SECONDS -lt $END ]; do
      curl -sSk -o /dev/null -H "Host: $DOMAIN" "https://$ELB/books" --max-time 3 &
      sleep "$SLEEP"
    done
    wait
  ) > "$LOAD_LOG" 2>&1 &
  LOAD_PID=$!
  echo "Started (pid $LOAD_PID)."
fi

echo
echo "── Watching alerts (Ctrl-C to stop early) ───────────────────────────"
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
  FIRING=$(curl -sS "http://$MONITORING_IP:9090/api/v1/alerts" --max-time 5 2>/dev/null \
    | jq -r '.data.alerts[] | select(.state=="firing") | "\(.labels.alertname): \(.annotations.summary)"' 2>/dev/null || true)
  if [ -n "$FIRING" ]; then
    echo "[$(date +%H:%M:%S)] FIRING:"
    echo "$FIRING" | sed 's/^/    /'
  else
    echo "[$(date +%H:%M:%S)] nothing firing yet..."
  fi
  sleep 15
done

echo
echo "Done. Prometheus: http://$MONITORING_IP:9090/alerts"
GRAFANA_IP=$(terraform output -raw grafana_url 2>/dev/null | sed 's|http://||' | cut -d: -f1)
[ -n "$GRAFANA_IP" ] && echo "Grafana:    http://$GRAFANA_IP:3000"
