#!/bin/bash
echo "Preparing the environment, this takes about 1-2 minutes..."
while [ ! -f /tmp/.setup-done ]; do
  if [ -f /tmp/.setup-failed ]; then
    echo "Environment setup failed. Please let your interviewer know."
    exit 1
  fi
  sleep 2
done
clear
echo "Environment ready. Start by running: tmate"
