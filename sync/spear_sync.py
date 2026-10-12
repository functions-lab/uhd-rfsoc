#!/usr/bin/env python3
"""spear_sync.py -- keep this repository in step with the SPEAR codebase.

Everything here that comes from SPEAR is listed in sync/manifest: which
upstream path maps to which local path, what is left out, and the few
rewrites this layout needs (paths, renamed files). A file is otherwise
byte-identical to its upstream after the rewrites, so syncing is mechanical:

  status                     local files that differ from rewrite(upstream@base)
  pull [--rev R | --worktree]
                             bring upstream changes in: per file a 3-way merge
                             (base = rewrite(upstream@base), theirs =
                             rewrite(upstream@R), ours = local); conflicts are
                             left with markers and listed; base moves to R
  push --into <SPEAR checkout>
                             carry local changes back: per file a 3-way merge
                             into the checkout's working tree (base =
                             upstream@base, theirs = unrewrite(local)); commit
                             there, then `pull` here to move the base

  --spear <path>  the SPEAR repository (default: sync/UPSTREAM's `repo`)

sync/UPSTREAM holds the repository path and the base commit (the upstream
revision this tree matches). `pull --worktree` reads the SPEAR working tree
instead of a commit (the first import of uncommitted work); it leaves the
base unset until a `pull --rev` binds it.
"""
import argparse, fnmatch, os, shlex, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def read_kv(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                d[k.strip()] = v.strip()
    return d


def write_kv(path, d):
    with open(path, 'w') as f:
        f.write('# spear_sync.py state: the SPEAR repository and the revision this tree matches\n')
        for k, v in d.items():
            f.write(f'{k} = {v}\n')


class Manifest:
    """sync/manifest: `map <upstream> <local>`, `exclude <glob>...`,
    `rewrite <local glob> <from> <to>` (quoted with shlex)."""

    def __init__(self, path):
        self.maps, self.excludes, self.rewrites = [], [], []
        for n, line in enumerate(open(path), 1):
            w = shlex.split(line, comments=True)
            if not w:
                continue
            if w[0] == 'map' and len(w) == 3:
                self.maps.append((w[1].rstrip('/'), w[2].rstrip('/')))
            elif w[0] == 'exclude':
                self.excludes += w[1:]
            elif w[0] == 'rewrite' and len(w) == 4:
                self.rewrites.append((w[1], w[2], w[3]))
            else:
                sys.exit(f'manifest line {n}: cannot parse: {line.rstrip()}')

    def excluded(self, up):
        parts = up.split('/')
        for g in self.excludes:
            if fnmatch.fnmatch(up, g) or any(fnmatch.fnmatch(p, g) for p in parts):
                return True
        return False

    def local_of(self, up):
        for u, l in sorted(self.maps, key=lambda m: -len(m[0])):
            if up == u:
                return l
            if up.startswith(u + '/'):
                return l + up[len(u):]
        return None

    def rules(self, local):
        return [(a, b) for g, a, b in self.rewrites if fnmatch.fnmatch(local, g)]

    def rewrite(self, local, data):
        for a, b in self.rules(local):
            data = data.replace(a.encode(), b.encode())
        return data

    def unrewrite(self, local, data):
        for a, b in reversed(self.rules(local)):
            data = data.replace(b.encode(), a.encode())
        return data


class Upstream:
    """Upstream files at a revision (git) or in the working tree (rev None)."""

    def __init__(self, repo, rev):
        self.repo, self.rev = repo, rev

    def files(self, prefixes):
        if self.rev is None:
            out = subprocess.run(['git', '-C', self.repo, 'ls-files', '--cached', '--others',
                                  '--exclude-standard', '--', *prefixes],
                                 capture_output=True, text=True, check=True).stdout
            return [f for f in out.split('\n') if f and os.path.isfile(os.path.join(self.repo, f))]
        out = subprocess.run(['git', '-C', self.repo, 'ls-tree', '-r', '--name-only', self.rev, '--', *prefixes],
                             capture_output=True, text=True, check=True).stdout
        return [f for f in out.split('\n') if f]

    def read(self, path):
        if self.rev is None:
            p = os.path.join(self.repo, path)
            return open(p, 'rb').read() if os.path.isfile(p) else None
        r = subprocess.run(['git', '-C', self.repo, 'show', f'{self.rev}:{path}'], capture_output=True)
        return r.stdout if r.returncode == 0 else None


def snapshot(man, up):
    """{local path: (upstream path, rewritten content)} of every mapped file."""
    snap = {}
    for f in up.files([u for u, _ in man.maps]):
        if man.excluded(f):
            continue
        l = man.local_of(f)
        if l is not None:
            snap[l] = (f, man.rewrite(l, up.read(f)))
    return snap


def merge3(ours, base, theirs, labels):
    """git merge-file on three byte strings -> (result, conflicted)."""
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for name, data in zip(('ours', 'base', 'theirs'), (ours, base, theirs)):
            p = os.path.join(d, name)
            open(p, 'wb').write(data or b'')
            paths.append(p)
        r = subprocess.run(['git', 'merge-file', '-p', '-L', labels[0], '-L', labels[1], '-L', labels[2], *paths],
                           capture_output=True)
        return r.stdout, r.returncode != 0


def cmd_status(man, st, repo):
    base = st.get('base')
    if not base:
        sys.exit('no base revision in sync/UPSTREAM: run `pull --rev <commit>` first')
    snap = snapshot(man, Upstream(repo, base))
    n = 0
    for l, (f, data) in sorted(snap.items()):
        p = os.path.join(ROOT, l)
        if not os.path.exists(p):
            print(f'missing   {l}  ({f})'); n += 1
        elif open(p, 'rb').read() != data:
            print(f'modified  {l}  ({f})'); n += 1
    print(f'{n} local difference(s) against {repo}@{base[:12]}')


def cmd_pull(man, st, repo, rev, worktree):
    new = Upstream(repo, None if worktree else rev)
    theirs = snapshot(man, new)
    base = snapshot(man, Upstream(repo, st['base'])) if st.get('base') else {}
    conflicts, changed = [], 0
    for l in sorted(set(theirs) | set(base)):
        p = os.path.join(ROOT, l)
        ours = open(p, 'rb').read() if os.path.exists(p) else None
        t = theirs.get(l, (None, None))[1]
        b = base.get(l, (None, None))[1]
        if t == b and l in base:
            continue                                   # unchanged upstream
        if t is None:                                  # deleted upstream
            if ours is not None and ours == b:
                os.remove(p); changed += 1; print(f'deleted   {l}')
            elif ours is not None:
                conflicts.append(l); print(f'CONFLICT  {l}: deleted upstream, modified here')
            continue
        if ours is None or ours == b or not base:
            if ours != t:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, 'wb').write(t); changed += 1
                print(f'{"added  " if ours is None else "updated"}   {l}')
            continue
        res, bad = merge3(ours, b or b'', t, ('local', 'base', 'upstream'))
        open(p, 'wb').write(res); changed += 1
        if bad:
            conflicts.append(l); print(f'CONFLICT  {l}')
        else:
            print(f'merged    {l}')
    if worktree:
        st['source'] = f'{repo} working tree'
        st.pop('base', None)
    else:
        st['base'] = subprocess.run(['git', '-C', repo, 'rev-parse', rev], capture_output=True,
                                    text=True, check=True).stdout.strip()
        st['source'] = f'{repo} {rev}'
    write_kv(os.path.join(HERE, 'UPSTREAM'), st)
    print(f'{changed} file(s) changed, {len(conflicts)} conflict(s); base {st.get("base", "unset (worktree import)")}')
    return 1 if conflicts else 0


def cmd_push(man, st, repo, into):
    if not st.get('base'):
        sys.exit('no base revision in sync/UPSTREAM')
    base_up = Upstream(repo, st['base'])
    conflicts, changed = [], 0
    for l, (f, _) in sorted(snapshot(man, base_up).items()):
        p = os.path.join(ROOT, l)
        if not os.path.exists(p):
            continue
        mine = man.unrewrite(l, open(p, 'rb').read())
        b = base_up.read(f)
        if mine == b:
            continue                                   # no local change
        q = os.path.join(into, f)
        cur = open(q, 'rb').read() if os.path.exists(q) else b''
        res, bad = merge3(cur, b, mine, ('spear', 'base', 'rfsoc-uhd'))
        open(q, 'wb').write(res); changed += 1
        if bad:
            conflicts.append(f); print(f'CONFLICT  {f}')
        else:
            print(f'pushed    {f}  (from {l})')
    print(f'{changed} file(s) written into {into}, {len(conflicts)} conflict(s); review and commit there, then pull here')
    return 1 if conflicts else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['status', 'pull', 'push'])
    ap.add_argument('--spear')
    ap.add_argument('--rev', default='HEAD')
    ap.add_argument('--worktree', action='store_true')
    ap.add_argument('--into')
    a = ap.parse_args()
    man = Manifest(os.path.join(HERE, 'manifest'))
    st = read_kv(os.path.join(HERE, 'UPSTREAM'))
    repo = a.spear or st.get('repo')
    if not repo:
        sys.exit('no SPEAR repository: pass --spear <path>')
    st['repo'] = repo
    if a.command == 'status':
        cmd_status(man, st, repo)
    elif a.command == 'pull':
        sys.exit(cmd_pull(man, st, repo, a.rev, a.worktree))
    else:
        if not a.into:
            sys.exit('push needs --into <SPEAR checkout>')
        sys.exit(cmd_push(man, st, repo, a.into))


main()
