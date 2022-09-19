RCLI_DIR=$${HOME}/.rcli/clis
DST=${RCLI_DIR}/vm/up

all: run

install:
	rm -rf "${DST}"
	mkdir -p "${DST}"
	ln -s $(CURDIR)/run "${DST}"
	ln -s $(CURDIR)/usage "${DST}"
	ln -s $(CURDIR)/help "${DST}"
