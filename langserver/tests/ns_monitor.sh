#!/bin/zsh
# Usage: ./ns_monitor.sh > /tmp/ns_cpu.txt
# Run while editing, kill with Ctrl-C

echo "time,cpu_pct,rss_mb"
while true; do
  PID=$(pgrep -x nimsuggest | tail -1)
  TS=$(date +%H:%M:%S.%3f)
  if [ -n "$PID" ]; then
    read CPU RSS <<< $(ps -p $PID -o %cpu=,rss= 2>/dev/null)
    RSS_MB=$(echo "$RSS" | awk '{printf "%.1f", $1/1024}')
    echo "$TS,$CPU,$RSS_MB"
  else
    echo "$TS,dead,-"
  fi
  sleep 0.25
done
