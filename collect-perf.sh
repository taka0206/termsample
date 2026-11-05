#!/bin/bash
# Supplied by GetPerf.ttl on stdin. Execute as the SSH user on RHEL.
set -u
export PATH=/usr/bin:/bin
umask 077
parent=${1:?missing perf parent}
stage=
cleanup() {
    [[ -n $stage ]] || return 0
    rm -f -- "$stage/perf.tar.gz" "$stage/tar.err" && rmdir -- "$stage"
}
fail() {
    printf '\nPF_FAIL:%s;\n' "$1"
    # Keep the PTY available long enough for the macro to read the diagnostic.
    IFS= read -r -t 5 _ </dev/tty || :
    exit 1
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
[[ $(id -un) == spfai001 ]] || fail LOGIN_USER
[[ $parent == /* ]] || fail ABSOLUTE_PATH
command -v scp >/dev/null || fail NO_SCP
stage=$(mktemp -d /var/tmp/ttperf.XXXXXXXXXX) || fail MKTEMP
printf '\nPF_STAGE:%s;\n' "$stage"
archive=$stage/perf.tar.gz

# Bash opens fds 3 and 4 as spfai001. Only the tar payload goes to fd 3.
# The parent is a positional argument, including spaces, quotes, or dollar signs.
# PAM communicates on the real tty even though this script came from a here-doc.
pack='
    [[ $EUID == 0 ]] || exit 41
    printf "\nPF_ROOT;\n"
    cd -P -- "$1" || exit 42
    [[ -d perf && ! -L perf ]] || exit 43
    unset TAR_OPTIONS GZIP
    exec /usr/bin/tar --format=posix --hard-dereference -czf - -- perf >&3 2>&4
'
LC_ALL=C /usr/bin/su --login --shell /bin/bash --command "$pack" root ttperf "$parent" \
    </dev/tty 3>"$archive" 4>"$stage/tar.err"
rc=$?
if (( rc != 0 )) || [[ -s $stage/tar.err ]]; then
    # tar can skip a socket with a warning and still return 0. Do not claim success.
    # Escape control characters from diagnostics before displaying them on the tty.
    LC_ALL=C sed -n '1,4l' "$stage/tar.err" >&2
    fail "PACK_$rc"
fi

# Check the actual immutable archive, not a second walk of the live source.
# tar preserves links and special entries. Only a Windows-representable tree
# may be materialized by Windows tar.exe. The archive is available in either case.
inventory='NO_PYTHON 0 0'
if [[ -x /usr/bin/python3 ]]; then
    inventory=$(/usr/bin/python3 -I - "$archive" <<'PYTHON_INVENTORY'
import re
import sys
import tarfile

forbidden = re.compile(r'[<>:"\\|?*\x00-\x1f]')
device = re.compile(r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|(?:COM|LPT)[0-9\u00b9\u00b2\u00b3])$', re.I)
alias = re.compile(r'~[0-9]+(?:\.|$)', re.I)
files = dirs = 0
names = set()
reason = "OK"
with tarfile.open(sys.argv[1], "r|gz", encoding="utf-8", errors="surrogateescape") as archive:
    for entry in archive:
        name = entry.name
        parts = name.split("/")
        if parts[0] != "perf" or any(p in ("", ".", "..") for p in parts):
            raise ValueError("unexpected archive path")
        if entry.isdir():
            dirs += 1
        elif entry.isfile():
            files += 1
        elif reason == "OK":
            reason = "LINK_OR_SPECIAL"
        if reason == "OK":
            part = parts[-1]  # GNU tar also emits an entry for each parent.
            try:
                utf16_len = len(part.encode("utf-16-le")) // 2
            except UnicodeEncodeError:
                utf16_len = 256
            stem = part.split(".", 1)[0].rstrip(" ")
            if (utf16_len > 255 or forbidden.search(part) or part.endswith((" ", "."))
                    or device.fullmatch(stem) or alias.search(part)):
                reason = "WINDOWS_NAME"
            key = name.upper()
            if key in names:
                reason = "NAME_COLLISION"
            names.add(key)
        archive.members.clear()
print(reason, files, dirs)
PYTHON_INVENTORY
    ) || fail INVENTORY
fi
read -r mode files dirs <<< "$inventory"
bytes=$(stat --format=%s -- "$archive") || fail SIZE
digest=$(sha256sum -- "$archive") || fail HASH
printf '\nPF_READY:%s:%s:%s:%s:%s;\n' "$bytes" "${digest%% *}" "$mode" "$files" "$dirs"

# The SCP channel is separate from this PTY; keep the archive until acknowledged.
# HUP on disconnect, or the 24-hour guard, also runs EXIT cleanup.
IFS= read -r -t 86400 ack </dev/tty || exit 1
[[ $ack == PF_RELEASE ]] || exit 1
cleanup || fail CLEANUP
stage=
printf '\nPF_CLEAN;\n'
IFS= read -r -t 10 _ </dev/tty || :
