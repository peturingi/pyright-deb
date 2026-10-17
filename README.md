# pyright-deb

Debian trixie packaging of [pyright](https://github.com/microsoft/pyright),
the Python static type checker and language server, built in a clean trixie
environment with [mkosi](https://github.com/systemd/mkosi). Nothing in the
build needs root.

Upstream is checked out as a git submodule in `pyright/`, pinned to a
release tag. The package installs:

- `/usr/bin/pyright`: command-line type checker
- `/usr/bin/pyright-langserver`: LSP server (`pyright-langserver --stdio`)
- `/usr/share/pyright/`: the rspack bundle, including the typeshed stubs

It runs on trixie's own `nodejs` (20.x) and has no other dependencies.

## Quick start

```sh
git clone --recurse-submodules https://github.com/peturingi/pyright-deb.git
cd pyright-deb
make                # builds mkosi.output/pyright_<version>-1_all.deb
sudo apt install ./mkosi.output/pyright_*_all.deb
```

`sudo` is only needed for that last step, installing the result on your
own system.

## Make targets

| Target           | What it does                                                         |
|------------------|----------------------------------------------------------------------|
| `make` / `make deb` | Build the `.deb` into `mkosi.output/`                             |
| `make test`      | Build the `.deb`, then a trixie container (`test/`) with it installed and smoke-tested |
| `make shell`     | Open a shell in that container (`systemd-nspawn`, unprivileged)     |
| `make boot`      | Boot that container with systemd as PID 1                            |
| `make update`    | Move the submodule to the latest stable pyright release, add a changelog entry, commit |
| `make clean`     | Remove the test container and built `.deb`s                          |
| `make distclean` | Also drop the package caches and pnpm store                          |

To run one command in the container: `mkosi -C test shell -- pyright --version`.

## Updating to a new pyright release

```sh
make update   # or: ./update-pyright 1.1.415 for a specific tag
make test
git push
```

`update-pyright` asks the GitHub API for the latest (non-prerelease)
release, checks the submodule out at that tag, prepends a
`debian/changelog` entry `<version>-1` and commits both. The build refuses
to run if `debian/changelog` and the submodule disagree on the version. For
a packaging-only change, add a `-2` changelog entry by hand.

## How the build works

`mkosi.conf` describes a trixie build environment (`Format=none`: no image
is kept, only the build's result). `mkosi.build.chroot` runs inside it and:

1. copies `pyright/` and `debian/` into `mkosi.builddir/pyright-<version>/`,
   so the submodule checkout stays clean;
2. installs the pnpm version pinned in upstream's `package.json`, using
   pnpm's standalone build (`@pnpm/exe`, which bundles its own Node). pnpm
   11 needs Node ≥ 22, newer than trixie has, but the actual build still
   runs on trixie's `nodejs`;
3. runs `pnpm install --frozen-lockfile` for just the CLI's workspace
   packages. This is the only step that uses the network (`WithNetwork=yes`);
4. runs `dpkg-buildpackage -b`, whose `debian/rules` builds the bundle with
   `pnpm --dir packages/pyright run build`;
5. copies the `.deb` to `mkosi.output/`.

`mkosi.builddir/` keeps the pnpm store between builds, and `mkosi.cache/`
keeps the trixie build environment (`Incremental=yes`). A rebuild takes
well under a minute.

The upstream test suite is not run. `test/mkosi.postinst.chroot` instead
installs the `.deb` into a fresh trixie tree, then checks `pyright
--version` and that a deliberately wrong file is reported.

## Running without root

### Building the `.deb`

You need unprivileged user namespaces, which Debian enables by default.
Check with `unshare --user --map-root-user true`.

mkosi then builds inside a user namespace where your UID is root. No
polkit, D-Bus or systemd configuration is involved. This works with
trixie's stock mkosi 25.3 as well as newer versions.

With mkosi ≥ 27, mkosi prefers a UID range from `systemd-nsresourced` when
that is available. On kernels before 7.3, mounting mkosi's build overlay
on top of such a range fails with
`PermissionError: [Errno 1] Operation not permitted: 'newroot/buildroot'`.
The Makefile therefore sets `MKOSI_FORCE_USERNS_FALLBACK=1` for the `.deb`
build. If you call mkosi directly, do the same:

```sh
MKOSI_FORCE_USERNS_FALLBACK=1 mkosi -f build
```

### The test container (`make test` / `make shell` / `make boot`)

Running `systemd-nspawn` without root needs more:

- **mkosi ≥ 27.1** (for `ForeignUIDRange=`). Trixie ships 25.3, so use a
  newer mkosi, e.g. a git checkout run via `bin/mkosi`.
- **systemd ≥ 260** on the host, for `systemd-nsresourced` and
  `systemd-mountfsd`. Trixie ships 257.
- Both sockets enabled. This is a one-time root step:

  ```sh
  sudo systemctl enable --now systemd-nsresourced.socket systemd-mountfsd.socket
  ```

- **polkit**: nsresourced's actions are allowed for everyone by default.
  mountfsd's `io.systemd.mount-file-system.mount-directory` is allowed
  without a password only from an *active* login session (a local or SSH
  login counts). From a cron job, a `systemd --user` service or a CI
  runner it asks for admin authentication. Grant it with a rule (replace
  `petur` with your user):

  ```js
  // /etc/polkit-1/rules.d/50-mkosi-unprivileged.rules
  polkit.addRule(function (action, subject) {
      if (subject.user == "petur" &&
          (action.id == "io.systemd.mount-file-system.mount-directory" ||
           action.id == "io.systemd.mount-file-system.mount-directory-privately")) {
          return polkit.Result.YES;
      }
  });
  ```

`test/mkosi.conf` sets `Register=no`. With registration enabled, an
unprivileged nspawn registers with your user's `systemd-machined` but then
aborts with `Failed to register machine in system context: Invalid request
descriptor`. As a result, the container does not appear in `machinectl`.

If you lack these host requirements, root still works:
`sudo mkosi -C test --foreign-uid-range=no -f build`, then
`sudo mkosi -C test --foreign-uid-range=no shell`. You don't need the
container to build or install the `.deb`.

Tested on Debian trixie (kernel 6.12), with mkosi 28~devel and systemd
263~devel for everything, and with mkosi 25.3 for the `.deb` build.

## Layout

```
mkosi.conf             trixie build environment for the .deb
mkosi.build.chroot     build script (runs inside it)
debian/                Debian packaging (debhelper 13)
pyright/               upstream, git submodule at a release tag
test/mkosi.conf        trixie container with the .deb installed
test/mkosi.postinst.chroot   installs and smoke-tests the .deb
update-pyright         bump to the latest upstream release
Makefile               convenience wrapper
```

## License

The packaging (everything outside `pyright/`) is MIT, like pyright itself;
see `debian/copyright`.
