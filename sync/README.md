# sync — keeping rfsoc-uhd in step with SPEAR

Everything this repository takes from SPEAR is listed in `manifest`:

- `map <SPEAR path> <local path>`: a file or a directory tree;
- `exclude <glob>`: never taken (build output, logs, `__pycache__`);
- `rewrite <local glob> <from> <to>`: the only local differences this layout
  needs (file names `zcu2xx_uhd_v49`, the IP root `fpga_ip/`, a few relative
  paths, the board checkout path). Applied on pull, reversed on push, in order:
  rules must not overlap.

After the rewrites every mapped file is byte-identical to its upstream, so
syncing in either direction is a per-file 3-way merge (`git merge-file`).
`UPSTREAM` records the SPEAR repository and the base commit this tree matches.

```
sync/spear_sync.py status                            # local files that differ from upstream@base
sync/spear_sync.py pull --rev <commit|branch>        # SPEAR -> here, base moves to <commit>
sync/spear_sync.py push --into <SPEAR checkout>      # here -> a SPEAR working tree (commit there,
                                                     # then `pull --rev` here to move the base)
sync/spear_sync.py pull --worktree                   # first import of uncommitted SPEAR work (no base)
```

`--spear <path>` overrides the repository in `UPSTREAM`. Conflicts are left
with `<<<<<<<` markers and listed; the exit code is non-zero then.

Workflow when SPEAR moves on: `pull --rev <new commit>`, review `git diff`,
build/test, commit here. When work is done here first: commit here,
`push --into <SPEAR checkout>`, commit in SPEAR, `pull --rev <that commit>`
here (a no-op merge that moves the base).

Longer term the cleaner end state is a single owner: once SPEAR stops
changing these files, make this repository the source and have SPEAR take it
as a git submodule; then nothing needs syncing.
