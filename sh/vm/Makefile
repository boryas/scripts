RCLI_DIR=$${HOME}/.rcli/clis
DST=${RCLI_DIR}/vm

all: run

install:
	rm -rf "${DST}"
	mkdir -p "${DST}"
	ln -s $(CURDIR)/run "${DST}"
	ln -s $(CURDIR)/usage "${DST}"
	ln -s $(CURDIR)/help "${DST}"
	$(MAKE) -C list install
	$(MAKE) -C up install
	$(MAKE) -C down install
	$(MAKE) -C ready install
	$(MAKE) -C cycle install
	$(MAKE) -C kill install
	$(MAKE) -C cons install
