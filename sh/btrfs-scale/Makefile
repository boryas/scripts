RCLI_DIR=$${HOME}/.rcli/clis
DST=${RCLI_DIR}/btrfs-scale

all: run

install:
	rm -rf "${DST}"
	mkdir -p "${DST}"
	ln -s $(CURDIR)/run "${DST}"
	ln -s $(CURDIR)/usage "${DST}"
	ln -s $(CURDIR)/help "${DST}"
	$(MAKE) -C files install
	$(MAKE) -C extents install
	$(MAKE) -C snapshots install

