#!/usr/bin/env python3
"""One bounded, metadata-only snapshot of an RR CI attempt, before owned cleanup.

Logical sums match regular-file st_size accounting. Allocated sums are st_blocks*512,
not exclusive APFS space. Unique sums deduplicate dev/inode, not cloned extents.
No file contents, symlink targets, host caches, or arbitrary TMPDIR are read.
"""
import heapq
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time

SCAN_SECONDS = 0.75
MAX_ENTRIES = 50000
MAX_DEPTH = 32
MAX_PATH = 160
MAX_OUTPUT = 24576
PREFIX = 'RRCI_SCRATCH_REPORT '
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Deadline(Exception):
    pass


def open_directory(path):
    """Open every absolute component without following symlinks, including ancestors."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('absolute owned path required')
    fd = os.open('/', DIR_FLAGS)
    try:
        for part in path.parts[1:]:
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def totals():
    return dict(files=0, logical_bytes=0, allocated_bytes=0,
                unique_files=0, unique_logical_bytes=0, unique_allocated_bytes=0)


def collect(root, seconds=SCAN_SECONDS, entries=MAX_ENTRIES, depth=MAX_DEPTH,
            clock=time.monotonic):
    started = clock()
    report = dict(schema=1, scope='owned-attempt:repo,home,tmp,root-files',
                  limits=dict(seconds=seconds, entries=entries, depth=depth,
                              path_characters=MAX_PATH, output_bytes=MAX_OUTPUT),
                  totals=totals(), roots={k: totals() for k in ('repo', 'home', 'tmp', 'root-files')},
                  visited_entries=0, skipped=dict(symlink=0, other=0, directory=0, errors=0),
                  partial=False, reasons=[], top_files=[])
    unique = set()
    root_unique = {k: set() for k in report['roots']}
    largest, gaps = [], []

    def partial(reason):
        report['partial'] = True
        if reason not in report['reasons']:
            report['reasons'].append(reason)

    def check():
        if clock() - started >= seconds:
            partial('deadline')
            raise Deadline()
        if report['visited_entries'] >= entries:
            partial('entry-limit')
            raise Deadline()

    def walk(fd, prefix='', level=0, bucket='root-files'):
        with os.scandir(fd) as children:
            for child in children:
                check()
                report['visited_entries'] += 1
                relative = prefix + child.name
                try:
                    info = child.stat(follow_symlinks=False)
                    if stat.S_ISLNK(info.st_mode):
                        report['skipped']['symlink'] += 1
                    elif stat.S_ISDIR(info.st_mode):
                        if not prefix and child.name not in ('repo', 'home', 'tmp'):
                            report['skipped']['directory'] += 1
                            partial('unregistered-directory')
                            continue
                        if level >= depth:
                            report['skipped']['directory'] += 1
                            partial('depth-limit')
                            continue
                        # Never reopen a directory through a path. O_NOFOLLOW also closes
                        # the lstat/open race if the app replaces an entry with a symlink.
                        sub = os.open(child.name, DIR_FLAGS, dir_fd=fd)
                        try:
                            actual = os.fstat(sub)
                            if (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino):
                                partial('directory-replaced')
                                continue
                            walk(sub, relative + '/', level + 1,
                                 bucket if prefix else child.name)
                        finally:
                            os.close(sub)
                    elif stat.S_ISREG(info.st_mode):
                        allocated = info.st_blocks * 512
                        key = (info.st_dev, info.st_ino)
                        for summary, seen in ((report['totals'], unique),
                                              (report['roots'][bucket], root_unique[bucket])):
                            summary['files'] += 1
                            summary['logical_bytes'] += info.st_size
                            summary['allocated_bytes'] += allocated
                            if key not in seen:
                                seen.add(key)
                                summary['unique_files'] += 1
                                summary['unique_logical_bytes'] += info.st_size
                                summary['unique_allocated_bytes'] += allocated
                        clipped = relative[:MAX_PATH]
                        row = dict(path=clipped, path_clipped=len(relative) > MAX_PATH,
                                   st_size=info.st_size, allocated_bytes=allocated,
                                   dev=info.st_dev, inode=info.st_ino, nlink=info.st_nlink)
                        # The visit index prevents comparisons between dictionaries on ties.
                        for heap, score, count in ((largest, info.st_size, 20),
                                                   (gaps, max(0, info.st_size - allocated), 12)):
                            item = (score, report['visited_entries'], row)
                            if len(heap) < count:
                                heapq.heappush(heap, item)
                            elif item[:2] > heap[0][:2]:
                                heapq.heapreplace(heap, item)
                    else:
                        report['skipped']['other'] += 1
                except OSError:
                    report['skipped']['errors'] += 1
                    partial('metadata-error')

    fd = None
    try:
        fd = open_directory(root)
        walk(fd)
    except Deadline:
        partial('deadline' if clock() - started >= seconds else 'entry-limit')
    except OSError:
        report['skipped']['errors'] += 1
        partial('root-unavailable')
    finally:
        if fd is not None:
            os.close(fd)
    selected = {item[1]: item for item in largest + gaps}
    report['top_files'] = [item[2] for item in sorted(selected.values(), reverse=True)]
    report['elapsed_seconds'] = round(clock() - started, 6)
    return report


def owned_root():
    """Bind the scan to this script's materialized, private RR CI attempt only."""
    root = Path(os.environ.get('RR_CI_OUTPUT', ''))
    attempt = os.environ.get('RR_CI_ATTEMPT', '')
    if (not root.is_absolute() or '..' in root.parts or not re.fullmatch('[0-9a-f]{32}', attempt)
            or root.name != attempt or root.parent.name != 'attempts'
            or Path(os.path.abspath(__file__)) != root / 'repo/scripts/rr/scratch-report.py'):
        raise ValueError('ownership guard')
    fd = open_directory(root)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('private owned attempt required')
    finally:
        os.close(fd)
    return root


def encode(report):
    def line():
        return PREFIX + json.dumps(report, ensure_ascii=True, separators=(',', ':')) + '\n'
    result = line()
    while len(result.encode('ascii')) > MAX_OUTPUT and report.get('top_files'):
        report['top_files'].pop()
        report['partial'] = True
        if 'output-limit' not in report['reasons']:
            report['reasons'].append('output-limit')
        result = line()
    return result


def main():
    def alarm(_signum, _frame):
        raise Deadline()

    # Worker TERM grace is 3s. Reserve >1s for interpreter startup and serialization.
    # This process starts from the EXIT trap after Swift receives group TERM.
    signal.signal(signal.SIGALRM, alarm)
    signal.setitimer(signal.ITIMER_REAL, 1.0)
    try:
        report = collect(owned_root())
    except (OSError, ValueError, Deadline):
        report = dict(schema=1, partial=True, reasons=['ownership-or-deadline'], top_files=[])
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    sys.stdout.write(encode(report))
    sys.stdout.flush()


if __name__ == '__main__':
    main()
