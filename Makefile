MKOSI ?= mkosi

# Before Linux 7.3 the kernel refuses mkosi's build overlay on top of the
# idmapped mounts systemd-nsresourced hands out, so the .deb build uses a
# plain unprivileged user namespace instead. The test container needs
# nsresourced (ForeignUIDRange=), so it must not get this variable.
DEB_ENV = MKOSI_FORCE_USERNS_FALLBACK=1

.PHONY: deb test shell boot update clean distclean

deb:
	$(DEB_ENV) $(MKOSI) -f build
	@ls -1 mkosi.output/*.deb

test: deb
	$(MKOSI) -C test -f build

shell:
	$(MKOSI) -C test shell

boot:
	$(MKOSI) -C test boot

update:
	./update-pyright

clean:
	$(MKOSI) -C test clean
	rm -f mkosi.output/*.deb

# Also drops the package caches and the pnpm store.
distclean:
	$(MKOSI) -C test -ff clean
	$(DEB_ENV) $(MKOSI) -ff clean
	rm -rf mkosi.output mkosi.builddir
