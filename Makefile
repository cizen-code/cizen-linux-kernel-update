PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SYSCONFDIR ?= /etc
UNITDIR_SYSTEM ?= $(SYSCONFDIR)/systemd/system
UNITDIR_USER ?= $(SYSCONFDIR)/systemd/user
SHELL := /bin/bash

.PHONY: install uninstall check-parity verify bash-n shellcheck selftest test clean

install:
	@$(SHELL) ./install.sh --prefix=$(PREFIX) --bindir=$(BINDIR)

uninstall:
	@$(SHELL) ./install.sh --uninstall --prefix=$(PREFIX) --bindir=$(BINDIR)

check-parity: verify
verify:
	@$(SHELL) ./scripts/verify-installed.sh --prefix=$(PREFIX) --bindir=$(BINDIR)

bash-n:
	@cd kernel-update && bash -n *.sh cizen-uki-sync

shellcheck:
	@cd kernel-update && shellcheck --severity=error *.sh cizen-uki-sync

selftest:
	@cd kernel-update && ./tests/selftest.sh

test: bash-n shellcheck selftest

clean:
	@rm -f MANIFEST.sha256
