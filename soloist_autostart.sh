#!/bin/sh
# orion-soloist-autostart-v2
set -eu
umask 077
B=/data/spotify-soloist
INIT=/etc/init.d/S99zsoloist
[ "$(id -u)" = 0 ] || { echo 'Нужен root.' >&2; exit 1; }
[ ! -L "$B" ] && [ "$(cat "$B/INSTALLER" 2>/dev/null)" = soloist-orion-v1 ] || { echo 'Установка Soloist не найдена.' >&2; exit 1; }
[ -f "$B/soloist.sh" ] && [ -s "$B/api.key" ] || { echo 'Сначала заверши установку Soloist.' >&2; exit 1; }
[ ! -L "$INIT" ] || { echo 'Init-скрипт оказался ссылкой.' >&2; exit 1; }
if [ -e "$INIT" ]; then
    grep -Eq '^# orion-soloist-autostart-v[12]$' "$INIT" || { echo "Посторонний файл $INIT; остановлено." >&2; exit 1; }
fi
cat > "$B/autostart.sh.new" <<'MANAGER'
#!/bin/sh
# orion-soloist-autostart-v2
set -eu
umask 077
B=/data/spotify-soloist
LOCK=/tmp/soloist-autostart-v2.lock
STOP=/tmp/soloist-autostart.stop
LOG=/tmp/soloist-autostart.log
DISABLED=$B/autostart.disabled
[ "$(id -u)" = 0 ] || { echo 'Нужен root.' >&2; exit 1; }
[ ! -L "$B" ] && [ "$(cat "$B/INSTALLER" 2>/dev/null)" = soloist-orion-v1 ] || { echo 'Установка Soloist не найдена.' >&2; exit 1; }
[ ! -L "$LOCK" ] || { echo 'Неверный каталог блокировки.' >&2; exit 1; }

cancelled() { [ -e "$STOP" ] || [ -e "$DISABLED" ]; }
worker_alive() {
    worker_pid=$(cat "$LOCK/pid" 2>/dev/null) || return 1
    case "$worker_pid" in ''|*[!0-9]*|0|1) return 1;; esac
    kill -0 "$worker_pid" 2>/dev/null || return 1
    tr '\000' '\n' 2>/dev/null < "/proc/$worker_pid/cmdline" | grep -Fxq "$B/autostart.sh" || return 1
    tr '\000' '\n' 2>/dev/null < "/proc/$worker_pid/cmdline" | grep -Fxq '_worker'
}
clear_stale_lock() {
    # Никогда не посылаем сигнал PID из файла: он мог быть переиспользован.
    [ -d "$LOCK" ] || return 0
    worker_alive && return 1
    # Даём новому процессу время записать PID после атомарного mkdir.
    if [ ! -f "$LOCK/pid" ]; then
        sleep 1
        worker_alive && return 1
    fi
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null
}
cancel_worker() {
    : > "$STOP"
    cancel_tries=0
    while [ -d "$LOCK" ]; do
        if clear_stale_lock; then break; fi
        if [ "$cancel_tries" -ge 60 ]; then
            echo 'Фоновый запуск ещё завершает команду. Повтори stop через несколько секунд.' >&2
            return 1
        fi
        sleep 1
        cancel_tries=$((cancel_tries+1))
    done
}
wait_or_cancel() {
    wait_left=$1
    while [ "$wait_left" -gt 0 ]; do
        cancelled && return 1
        sleep 1
        wait_left=$((wait_left-1))
    done
    ! cancelled
}
case "${1:-status}" in
    boot)
        cancelled && exit 0
        [ -s "$B/api.key" ] || { echo 'Не задан API-ключ Soloist.' >&2; exit 1; }
        # init не ждёт сеть. Worker сам получает блокировку до открытия лога.
        nohup sh "$B/autostart.sh" _worker </dev/null >/dev/null 2>&1 &
        ;;
    _worker)
        cancelled && exit 0
        if ! mkdir "$LOCK" 2>/dev/null; then
            clear_stale_lock || exit 0
            mkdir "$LOCK" 2>/dev/null || exit 0
        fi
        trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || :' EXIT
        trap 'exit 1' HUP INT TERM
        printf '%s\n' "$$" > "$LOCK/pid"
        [ ! -f "$LOG" ] || mv "$LOG" /tmp/soloist-autostart.previous.log
        exec >>"$LOG" 2>&1
        date
        echo 'Waiting for audio and network...'
        wait_or_cancel 15 || exit 0
        network_tries=0
        while [ "$network_tries" -lt 60 ]; do
            cancelled && exit 0
            if [ -r /etc/asound.conf ] && awk 'NR>1 && $2=="00000000" && $1!="lo" { found=1 } END { exit !found }' /proc/net/route; then
                break
            fi
            wait_or_cancel 2 || exit 0
            network_tries=$((network_tries+1))
        done
        attempt=1
        while [ "$attempt" -le 3 ]; do
            cancelled && exit 0
            if sh "$B/soloist.sh" start; then exit 0; fi
            echo "Soloist: start attempt $attempt/3 failed."
            attempt=$((attempt+1))
            [ "$attempt" -gt 3 ] || wait_or_cancel 15 || exit 0
        done
        exit 1
        ;;
    start)
        cancel_worker
        rm -f "$STOP"
        exec sh "$B/soloist.sh" start
        ;;
    stop)
        cancel_worker
        exec sh "$B/soloist.sh" stop
        ;;
    restart)
        cancel_worker
        sh "$B/soloist.sh" stop
        rm -f "$STOP"
        exec sh "$B/soloist.sh" start
        ;;
    enable)
        rm -f "$DISABLED"
        echo 'Автозапуск включён. Для запуска сейчас: autostart.sh start'
        ;;
    disable)
        : > "$DISABLED"
        cancel_worker
        echo 'Автозапуск отключён. Уже запущенная музыка продолжает работать.'
        ;;
    status)
        if [ -e "$DISABLED" ]; then echo 'Автозапуск: выключен'; else echo 'Автозапуск: включён'; fi
        if worker_alive; then echo 'Фоновый запуск: выполняется'; fi
        exec sh "$B/soloist.sh" status
        ;;
    logs)
        if [ -f "$LOG" ]; then tail -n 50 "$LOG"; else echo 'Лога автозапуска пока нет.'; fi
        exec sh "$B/soloist.sh" logs
        ;;
    *) echo 'Команды: start, stop, restart, enable, disable, status, logs' >&2; exit 1 ;;
esac
MANAGER
chmod 700 "$B/autostart.sh.new"
sh -n "$B/autostart.sh.new"
mv "$B/autostart.sh.new" "$B/autostart.sh"
root_options=$(awk '$2=="/" {print $4; exit}' /proc/mounts)
[ -n "$root_options" ] || { echo 'Не определён режим корневой файловой системы.' >&2; exit 1; }
restore_ro=0
cleanup() {
    rm -f "$INIT.new"
    sync
    if [ "$restore_ro" = 1 ]; then mount -o remount,ro /; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
case ",$root_options," in *,ro,*) mount -o remount,rw /; restore_ro=1;; esac
cat > "$INIT.new" <<'INIT_SCRIPT'
#!/bin/sh
# orion-soloist-autostart-v2
case "${1:-start}" in
    start) exec sh /data/spotify-soloist/autostart.sh boot ;;
    *) exec sh /data/spotify-soloist/autostart.sh "$@" ;;
esac
INIT_SCRIPT
chmod 755 "$INIT.new"
sh -n "$INIT.new"
mv "$INIT.new" "$INIT"
sync
echo 'Автозапуск v2 установлен. Сервисы не перезапускались.'
echo 'После обновления прежнего автозапуска перезагрузи колонку.'
sh "$B/autostart.sh" status