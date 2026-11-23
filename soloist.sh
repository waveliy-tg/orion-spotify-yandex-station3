#!/bin/sh
set -eu
umask 077
B=/data/spotify-soloist
R=/tmp/spotify-soloist
L=$B/root/usr/lib/aarch64-linux-gnu
LD=$L/ld-linux-aarch64.so.1
MODULES=$B/root/usr/lib/pulse-17.0+dfsg1/modules
LIBS=$L:$L/pulseaudio:$MODULES:$B/root/usr/lib

die() { printf '%s\n' "$*" >&2; exit 1; }
owned() {
    [ "$(id -u)" = 0 ] || die 'Нужен root.'
    [ ! -L "$B" ] && [ "$(cat "$B/INSTALLER" 2>/dev/null)" = soloist-orion-v1 ] || die 'Не найдена собственная установка.'
}
environment() {
    unset LD_LIBRARY_PATH LD_PRELOAD ALSA_CONFIG_PATH ALSA_CONFIG_DIR ALSA_PLUGIN_DIR
    export SSL_CERT_FILE=$B/cacert.pem
    export XDG_CONFIG_HOME=$B/xdg
    export XDG_CACHE_HOME=$R/cache
    export XDG_RUNTIME_DIR=$R
    export PULSE_RUNTIME_PATH=$R/pulse
    export PULSE_STATE_PATH=$B/pulse-state
    export PULSE_CONFIG_PATH=$B/pulse-conf
    export PULSE_SERVER=unix:$R/native
    export PULSE_SINK=orion
    export ALSA_CONFIG_DIR=$B/root/usr/share/alsa
    export ALSA_CONFIG_PATH=$B/root/usr/share/alsa/alsa.conf
    export ALSA_PLUGIN_DIR=$L/alsa-lib
}
run() { "$LD" --library-path "$LIBS" "$@"; }
redact() {
    awk -v keyfile="$B/api.key" '
        BEGIN { getline key < keyfile; close(keyfile) }
        { line=$0; result="";
          if (length(key)>0) {
            while ((p=index(line,key))>0) {
              result=result substr(line,1,p-1) "[KEY HIDDEN]";
              line=substr(line,p+length(key));
            }
          }
          print result line;
        }'
}
valid() {
    p=$1; target=$2
    case "$p" in ''|*[!0-9]*|0|1) return 1;; esac
    kill -0 "$p" 2>/dev/null || return 1
    [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f "$LD")" ] || return 1
    tr '\000' '\n' < "/proc/$p/cmdline" | grep -Fxq "$target"
}
getpid() {
    kind=$1; target=$2
    if [ -r "$R/$kind.pid" ]; then
        p=$(cat "$R/$kind.pid")
        if valid "$p" "$target"; then printf '%s\n' "$p"; return 0; fi
    fi
    for proc in /proc/[0-9]*/exe; do
        p=${proc#/proc/}; p=${p%/exe}
        if valid "$p" "$target"; then printf '%s\n' "$p"; return 0; fi
    done
    return 1
}
stop_one() {
    kind=$1; target=$2
    if p=$(getpid "$kind" "$target"); then
        kill -TERM "$p"
        tries=0
        while valid "$p" "$target"; do
            [ "$tries" -lt 12 ] || die "$kind не завершился: PID $p"
            sleep 1; tries=$((tries+1))
        done
    fi
    rm -f "$R/$kind.pid"
}
setup_files() {
    [ ! -L "$R" ] || die 'Runtime оказался ссылкой.'
    mkdir -p "$R/pulse" "$R/cache" "$B/state" "$B/pulse-state" "$B/xdg" "$B/pulse-conf"
    chmod 700 "$R" "$R/pulse" "$B/state"
    cat > "$B/pulse-conf/daemon.conf" <<'CONF'
daemonize = no
system-instance = no
exit-idle-time = -1
flat-volumes = no
enable-shm = no
high-priority = no
realtime-scheduling = no
resample-method = trivial
default-sample-format = s16le
default-sample-rate = 48000
alternate-sample-rate = 44100
CONF
    cat > "$B/default.pa" <<CONF
.fail
load-module module-alsa-sink device=plug:speakers sink_name=orion channels=2 rate=48000 format=s16le tsched=0
load-module module-suspend-on-idle timeout=2
load-module module-native-protocol-unix socket=$R/native auth-anonymous=1
set-default-sink orion
CONF
}
launch() {
    owned; setup_files
    [ -s "$B/api.key" ] || die 'Не введён личный API-ключ Soloist: запусти Python-установщик с командой key.'
    if [ -f /data/spotify-orion/INSTALLER ] && [ -f /data/spotify-orion/orion_spotify.sh ]; then
        sh /data/spotify-orion/orion_spotify.sh stop
    fi
    if ! p=$(getpid pulse "$B/root/usr/bin/pulseaudio"); then
        [ ! -f "$R/pulse.log" ] || tail -c 131072 "$R/pulse.log" > "$R/pulse.previous.log"
        rm -f "$R/native"
        nohup sh "$B/soloist.sh" _pulse </dev/null > "$R/pulse.log" 2>&1 &
        printf '%s\n' "$!" > "$R/pulse.pid"
        tries=0
        while [ ! -S "$R/native" ]; do
            sleep 1; tries=$((tries+1))
            if [ "$tries" -ge 10 ]; then tail -n 35 "$R/pulse.log" | redact; die 'PulseAudio не поднялся.'; fi
        done
    fi
    # Проверяем клиентский протокол до запуска Spotify.
    environment
    run "$B/root/usr/bin/pactl" info > "$R/pulse-info.txt" || die 'PulseAudio не отвечает.'
    if p=$(getpid soloist "$B/soloist"); then
        printf 'Soloist уже работает, PID %s.\n' "$p"; return
    fi
    [ ! -f "$R/soloist.log" ] || tail -c 131072 "$R/soloist.log" > "$R/soloist.previous.log"
    nohup sh "$B/soloist.sh" _soloist </dev/null > "$R/soloist.log" 2>&1 &
    p=$!; printf '%s\n' "$p" > "$R/soloist.pid"
    sleep 3
    if ! valid "$p" "$B/soloist"; then
        tail -n 40 "$R/soloist.log" | redact; die 'Soloist завершился при запуске.'
    fi
    printf '%s\n' 'PulseAudio и Soloist запущены. Открой Spotify в той же Wi-Fi сети и выбери Yandex Station 3 Soloist.'
}

action=${1:-status}
case "$action" in
    update)
        owned
        dest=$B/soloist.sh
        [ -f "$dest" ] && [ ! -L "$dest" ] || die 'Не найден штатный скрипт Soloist.'
        if cmp -s "$0" "$dest"; then echo 'Обновление уже установлено.'; exit 0; fi
        sum=$(sha256sum "$dest") || die 'Не удалось проверить версию.'
        [ "${sum%% *}" = 0f383aeb9c76750f474fed90efc37c53ee960b221d829e2827ed8ba4b87d9c9b ] ||
            die 'Версия soloist.sh отличается от исходной. Обновление остановлено.'
        tmp=$(mktemp "$B/soloist.sh.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        cat "$0" > "$tmp"
        sh -n "$tmp"
        chmod 700 "$tmp"
        mv -f "$tmp" "$dest"
        echo 'Скрипт Soloist обновлён. Новая настройка вступит в силу при следующем запуске PulseAudio.'
        ;;
    audio-status)
        owned; environment
        run "$B/root/usr/bin/pactl" list short sinks
        ;;
    verify)
        owned; setup_files; environment
        run "$B/soloist" --version
        run "$B/root/usr/bin/pulseaudio" --version
        run "$B/root/usr/bin/pactl" --version
        ;;
    start) launch ;;
    _pulse)
        owned; environment
        exec "$LD" --library-path "$LIBS" "$B/root/usr/bin/pulseaudio" \
            --daemonize=no --system=no --use-pid-file=no --exit-idle-time=-1 \
            --log-target=stderr --log-level=warning --dl-search-path="$MODULES" \
            -n -F "$B/default.pa"
        ;;
    _soloist)
        owned; environment
        key=$(cat "$B/api.key")
        exec "$LD" --library-path "$LIBS" "$B/soloist" \
            --device-name 'Yandex Station 3 Soloist' --api-key "$key" \
            --data-dir "$B/state" --cache-dir "$R/cache" --cache-size 100 --initial-volume 30
        ;;
    stop)
        owned
        stop_one soloist "$B/soloist"
        stop_one pulse "$B/root/usr/bin/pulseaudio"
        printf '%s\n' 'Soloist и собственный PulseAudio остановлены.'
        ;;
    status)
        owned
        for kind in soloist pulse; do
            if [ "$kind" = soloist ]; then target=$B/soloist; else target=$B/root/usr/bin/pulseaudio; fi
            if p=$(getpid "$kind" "$target"); then printf '%s: PID %s\n' "$kind" "$p"; else printf '%s: остановлен\n' "$kind"; fi
        done
        ;;
    logs)
        owned
        for log in pulse soloist; do
            printf '\n--- %s ---\n' "$log"
            [ ! -f "$R/$log.log" ] || tail -n 45 "$R/$log.log" | redact
        done
        ;;
    *) die 'Команды: verify, start, stop, status, logs.' ;;
esac
