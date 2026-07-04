#!/usr/bin/env bash
# LocalSend headless 接收进程的启停脚本。
# 用 setsid 完全脱离会话,reparent 到 init,避免被 harness 的进程组清理杀掉。
set -u

BIN=/home/chenxiaobai/Projects/localsend/cli/localsend
DEST=/tmp/ls_recv_test
LOG=/tmp/ls_recv.log
PIDFILE=/tmp/ls_recv.pid
ALIAS="Linux"

cmd="${1:-status}"
case "$cmd" in
  start)
    # 先清掉可能残留的旧进程
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "already running pid=$(cat "$PIDFILE")"
      exit 0
    fi
    pkill -f "localsend receive" 2>/dev/null || true
    sleep 0.3
    mkdir -p "$DEST"
    : > "$LOG"
    # setsid + 全部重定向 → 真守护进程,不随 shell 退出而死
    setsid bash -c "\"$BIN\" receive --alias \"$ALIAS\" --dest \"$DEST\" >> \"$LOG\" 2>&1 < /dev/null" &
    echo $! > "$PIDFILE"
    disown 2>/dev/null || true
    sleep 1.2
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "started pid=$(cat "$PIDFILE") dest=$DEST"
    else
      echo "FAILED to start, log:"
      cat "$LOG"
    fi
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null && echo "stopped pid=$(cat "$PIDFILE")"
      rm -f "$PIDFILE"
    fi
    pkill -f "localsend receive" 2>/dev/null && echo "stopped (pkill)" || echo "no process"
    ;;
  restart)
    "$0" stop
    sleep 0.5
    "$0" start
    ;;
  log)
    tail -n "${2:-40}" "$LOG"
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "running pid=$(cat "$PIDFILE")"
    else
      echo "not running"
    fi
    ss -lntu 2>/dev/null | grep 53317 || echo "53317 no listen"
    echo "--- dest ---"
    ls -la "$DEST" 2>/dev/null
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|log [n]}"
    exit 64
    ;;
esac
