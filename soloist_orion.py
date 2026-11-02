#!/usr/bin/env python3
"""Установщик официального Spotify Soloist в отдельную среду Orion.

Windows: py -3 soloist_orion.py 192.168.1.101 install
Ключ Soloist вводится скрыто в терминале. В чат его присылать не нужно.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import copy
import getpass
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import ssl
import struct
import tarfile
import tempfile
import time
import urllib.request

from orion_transport import Station, SetupError, find_adb

HERE = Path(__file__).resolve().parent
BASE = "/data/spotify-soloist"
SOLOIST_URL = "https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz"
KEY_PAGE = "https://developer.spotify.com/dashboard/soloist"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024*1024), b""): h.update(block)
    return h.hexdigest()


def download(url, destination, expected=None, limit=150*1024*1024):
    destination = Path(destination)
    if expected and destination.is_file() and digest(destination) == expected:
        return destination
    temp = destination.with_suffix(destination.suffix + ".part")
    context = ssl.create_default_context(cafile=str(HERE / "cacert.pem"))
    request = urllib.request.Request(url, headers={"User-Agent": "OrionSoloistSetup/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60, context=context) as response, temp.open("wb") as out:
            size = 0
            while block := response.read(1024*1024):
                size += len(block)
                if size > limit: raise SetupError("Неожиданный размер скачивания.")
                out.write(block)
        if expected and digest(temp) != expected:
            raise SetupError("SHA256 скачанного пакета не совпала: " + destination.name)
        temp.replace(destination)
    finally:
        temp.unlink(missing_ok=True)
    return destination


def deb_data(path):
    """Стандартный ar-контейнер .deb; без dpkg/ar на Windows."""
    with Path(path).open("rb") as f:
        if f.read(8) != b"!<arch>\n": raise SetupError("Неверный формат .deb")
        while header := f.read(60):
            if len(header) != 60 or header[58:] != b"`\n": raise SetupError("Повреждённый .deb")
            name = header[:16].decode("ascii").strip().rstrip("/")
            length = int(header[48:58])
            data = f.read(length)
            if len(data) != length: raise SetupError("Неполный .deb")
            if length % 2: f.read(1)
            if name.startswith("data.tar"):
                return tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    raise SetupError("В .deb нет data.tar")


def safe_name(name):
    name = name.removeprefix("./")
    if not name or name.startswith("/") or ".." in PurePosixPath(name).parts:
        raise SetupError("Недопустимый путь в архиве")
    return name


def add_runtime(output, debs):
    seen = set()
    for deb in debs:
        with deb_data(deb) as data:
            for member in data:
                name = safe_name(member.name)
                if not name.startswith(("usr/lib/", "usr/bin/", "usr/share/alsa/")):
                    continue
                if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    continue
                if name in seen: continue
                seen.add(name)
                m = copy.copy(member)
                m.name = "root/" + name
                m.uid = m.gid = 0
                m.uname = m.gname = "root"
                m.mode &= 0o777
                if m.issym():
                    target = member.linkname
                    if target.startswith("/"):
                        target = posixpath.relpath(target.lstrip("/"), posixpath.dirname(name))
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                    if resolved == ".." or resolved.startswith("../"):
                        raise SetupError("Ссылка выходит за пределы среды")
                    m.linkname = target
                elif m.islnk():
                    m.linkname = "root/" + safe_name(member.linkname)
                stream = data.extractfile(member) if m.isfile() else None
                try: output.addfile(m, stream)
                finally:
                    if stream is not None: stream.close()


def add_file(output, name, data, mode=0o600):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    output.addfile(info, io.BytesIO(data))


def payload(destination, cache):
    manifest = json.loads((HERE / "runtime_manifest.json").read_text(encoding="utf-8"))
    print(f"[1/5] Библиотеки Debian: {len(manifest)} пакетов, {sum(p['size'] for p in manifest)//1048576} МБ.", flush=True)
    def fetch(item):
        return download(item["url"], cache / (item["name"] + ".deb"), item["sha256"], item["size"]+1024)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        debs = []
        for i, path in enumerate(pool.map(fetch, manifest), 1):
            debs.append(path)
            print(f"  {i}/{len(manifest)} {path.stem}", flush=True)
    print("[2/5] Скачиваю официальный Soloist с сервера Spotify…", flush=True)
    # Закрытый бинарник не входит в комплект установщика, каждый пользователь
    # скачивает его с официального CDN согласно документации Spotify.
    soloist_archive = cache / "soloist_latest.tar.gz"
    if soloist_archive.is_file() and 0 <= time.time() - soloist_archive.stat().st_mtime < 86400:
        print("  Использую уже скачанный Soloist (кэш моложе суток).", flush=True)
    else:
        soloist_archive = download(SOLOIST_URL, soloist_archive)
    with tarfile.open(soloist_archive) as source:
        member = next((m for m in source if m.isfile() and PurePosixPath(m.name).name == "soloist"), None)
        if not member or member.size > 100*1024*1024: raise SetupError("В архиве Spotify нет подходящего soloist")
        with source.extractfile(member) as f: soloist = f.read()
    if soloist[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", soloist, 18)[0] != 183:
        raise SetupError("Soloist не является ARM64 ELF")
    print("[3/5] Собираю отдельную среду…", flush=True)
    # BusyBox Orion собран без tar -z. Распаковываем .deb и gzip на ПК;
    # на колонку передаётся обычный POSIX tar без сжатия.
    with tarfile.open(destination, "w", format=tarfile.USTAR_FORMAT) as out:
        add_runtime(out, debs)
        add_file(out, "soloist", soloist, 0o700)
        add_file(out, "soloist.sh", (HERE / "soloist.sh").read_text(encoding="utf-8").encode(), 0o700)
        add_file(out, "cacert.pem", (HERE / "cacert.pem").read_bytes())
        add_file(out, "INSTALLER", b"soloist-orion-v1\n")


def control(station, command):
    output = station.shell("sh", BASE + "/soloist.sh", command, timeout=60)
    print(output, end="" if output.endswith("\n") else "\n")


def set_key(station, path=None):
    control(station, "stop")
    if path:
        key = Path(path).read_text(encoding="utf-8-sig").strip()
    else:
        print("Создай свой Soloist API key: " + KEY_PAGE)
        key = getpass.getpass("Вставь ключ здесь (ввод скрыт), Enter: ").strip()
    if not key or len(key) > 8192 or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise SetupError("Ключ пустой или содержит пробелы/переносы строк.")
    # Секрет передаётся отдельным приватным файлом, не через argv/лог ADB.
    remote_temp = BASE + "/api.key.new"
    with tempfile.TemporaryDirectory(prefix="soloist-key-") as folder:
        local = Path(folder) / "api.key"
        local.write_bytes(key.encode("ascii"))
        os.chmod(local, 0o600)
        try:
            station.call("push", str(local), remote_temp, timeout=45)
            station.shell("chmod", "600", remote_temp)
            station.shell("mv", remote_temp, BASE + "/api.key")
        finally:
            station.shell("rm", "-f", remote_temp, timeout=10)
    print("Личный ключ сохранён на колонке.")


def install(station, args):
    preflight = (
        '[ "$(id -u)" = 0 ] && [ "$(uname -m)" = aarch64 ] '
        '&& [ -e /sys/class/leds/orion:blue:ring0 ] '
        '&& [ -r /etc/asound.conf ] && [ -w /data ] && echo SOLOIST_ORION_OK'
    )
    if "SOLOIST_ORION_OK" not in station.shell("sh", "-c", preflight).splitlines():
        raise SetupError("Не подтверждён root/Orion/ALSA/доступ к /data")
    if "EXISTS" in station.shell("sh", "-c", f"if [ -e {BASE} ]; then echo EXISTS; fi").splitlines():
        raise SetupError("Soloist уже установлен. Команды: start, key, verify, status, logs, stop.")
    df = station.shell("df", "-Pk", "/data")
    lines = [line.split() for line in df.splitlines() if line.startswith("/dev/")]
    if not lines or int(lines[-1][3]) < 600000:
        raise SetupError("Для установки нужно не менее 600 МБ свободного места на /data.")
    cache = HERE / "soloist_downloads"
    cache.mkdir(exist_ok=True)
    import uuid
    stage = "/data/spotify-soloist-stage-" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="soloist-runtime-") as folder:
        archive = Path(folder) / "payload.tar"
        payload(archive, cache)
        print("[4/5] Передаю и распаковываю файлы на колонке…", flush=True)
        station.shell("mkdir", "-m", "700", stage)
        try:
            remote_archive = stage + "/payload.tar"
            station.call("push", str(archive), remote_archive, timeout=300)
            if station.shell("sha256sum", remote_archive).split()[0] != digest(archive):
                raise SetupError("Контрольная сумма переданного архива не совпала")
            station.shell("tar", "x", "-f", remote_archive, "-C", stage, timeout=180)
            station.shell("rm", "-f", remote_archive)
            station.shell("mv", stage, BASE)
        finally:
            station.shell("rm", "-rf", stage, timeout=30)
    print("[5/5] Проверяю настоящий ARM64-клиент и звуковые библиотеки…", flush=True)
    control(station, "verify")
    set_key(station, args.key_file)
    control(station, "start")
    print("\nВ Spotify выбери Yandex Station 3 Soloist. Телефон и колонка должны быть в одной Wi-Fi сети.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="IP колонки / serial ADB")
    parser.add_argument("action", nargs="?", default="install", choices=["install", "key", "verify", "start", "stop", "status", "logs"])
    parser.add_argument("--adb", help="Путь к adb.exe")
    parser.add_argument("--key-file", help="Локальный файл с личным API-ключом вместо скрытого ввода")
    args = parser.parse_args()
    try:
        station = Station(find_adb(args.adb), args.target)
        station.connect()
        if args.action == "install": install(station, args)
        elif args.action == "key": set_key(station, args.key_file)
        else: control(station, args.action)
        return 0
    except KeyboardInterrupt:
        print("\nПрервано. Для остановки сервисов: py -3 soloist_orion.py " + args.target + " stop")
        return 130
    except Exception as error:
        # Не включаем значения ключа в текст ошибки.
        print("Ошибка: " + str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
