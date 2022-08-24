RCLI_DIR=$${HOME}/.rcli/clis
DST=${RCLI_DIR}/vm-baseline

all: run

install: run usage help
	rm -rf "${DST}"
	mkdir -p "${DST}"
	ln -s $(CURDIR)/run "${DST}"
	ln -s $(CURDIR)/usage "${DST}"
	ln -s $(CURDIR)/help "${DST}"
