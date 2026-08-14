#!/bin/bash
DIR=/workspaces/tests/.keepalive
while true; do
  bash "$DIR/ensure_stack.sh" >>"$DIR/tunnel_guard.log" 2>&1 || true
  sleep 110
done
