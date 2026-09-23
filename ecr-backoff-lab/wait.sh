#!/bin/bash
# Shows setup progress to the candidate. Details: /var/log/scenario-timing.log
START=$(date +%s)
LAST=""
STEP_T=$START
echo "Preparing the environment (usually 1-3 minutes)..."
echo
while [ ! -f /tmp/.setup-done ]; do
  NOW=$(date +%s)
  if [ -f /tmp/.setup-failed ]; then
    echo
    echo
    echo "Environment setup failed at $(cat /tmp/.setup-failed) after $((NOW - START))s."
    echo "Please let your interviewer know."
    exit 1
  fi
  CUR=$(cat /tmp/.setup-progress 2>/dev/null || echo "Starting")
  if [ "$CUR" != "$LAST" ]; then
    [ -n "$LAST" ] && printf "\r  ✔ %-45s %4ss\n" "$LAST" "$((NOW - STEP_T))"
    LAST=$CUR
    STEP_T=$NOW
  fi
  EL=$((NOW - STEP_T))
  NOTE=""
  [ "$EL" -ge 120 ] && NOTE=" (taking longer than usual)"
  printf "\r  … %-45s %4ss%s" "$CUR" "$EL" "$NOTE"
  sleep 1
done
[ -n "$LAST" ] && printf "\r  ✔ %-45s %4ss\n" "$LAST" "$(( $(date +%s) - STEP_T ))"
echo
echo "Environment ready in $(( $(date +%s) - START ))s. Start by running: share-terminal"