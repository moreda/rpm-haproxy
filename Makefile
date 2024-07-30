HOME=$(shell pwd)
MAINVERSION?=2.9
NO_SUDO?=0
USE_PODMAN?=0
LUA_VERSION?=5.4.7
USE_LUA?=1
USE_PROMETHEUS?=1
CPU?=0
VERSION=$(shell curl -s http://git.haproxy.org/git/haproxy-${MAINVERSION}.git/refs/tags/ | sed -n 's:.*>\(.*\)</a>.*:\1:p' | sed 's/^.//' | sort -rV | head -1)
ifeq ("${VERSION}","./")
		VERSION="${MAINVERSION}.0"
endif
RELEASE?=1
EXTRA_CFLAGS?=0
PREREQ:=pcre-devel make gcc openssl-devel rpm-build systemd-devel curl sed zlib-devel
ifeq ($(NO_SUDO),1)
	SUDO=
else
	SUDO=sudo
endif

HAS_DNF:=$(shell command -v dnf 2> /dev/null)
ifdef HAS_DNF
	PACKAGE_MANAGER=dnf
	INSTALL_FLAGS=-y --allowerasing
else
	PACKAGE_MANAGER=yum
	INSTALL_FLAGS=-y
endif

ifeq ($(USE_PODMAN),1)
	CONTAINER_RUNTIME=podman
else
	CONTAINER_RUNTIME=docker
endif

.ONESHELL:

all: build

install_prereq:
	# Check if the prereqs are there before trying to sudo
	rpm -q $(PREREQ) || \
		$(SUDO) $(PACKAGE_MANAGER) install $(INSTALL_FLAGS) $(PREREQ)

clean:
	rm -f ./SOURCES/haproxy-*.tar.gz
	rm -rf ./SOURCES/lua-*
	rm -rf ./rpmbuild
	mkdir -p ./rpmbuild/SPECS/ ./rpmbuild/SOURCES/ ./rpmbuild/RPMS/ ./rpmbuild/SRPMS/

download-upstream:
	curl -o ./SOURCES/haproxy-${VERSION}.tar.gz http://www.haproxy.org/download/${MAINVERSION}/src/haproxy-${VERSION}.tar.gz

build_lua:
	rpm -q readline-devel || $(SUDO) yum install -y readline-devel
	curl -o ./SOURCES/lua-${LUA_VERSION}.tar.gz https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz
	cd ./SOURCES
	tar xzf lua-${LUA_VERSION}.tar.gz
	$(MAKE) -C lua-${LUA_VERSION} clean
	$(SUDO) $(MAKE) -C lua-${LUA_VERSION} MYCFLAGS=-fPIC linux test  # MYCFLAGS=-fPIC is required during linux ld
	$(SUDO) $(MAKE) -C lua-${LUA_VERSION} install

build_stages := install_prereq clean download-upstream
ifeq ($(USE_LUA),1)
	build_stages += build_lua
endif

build-docker:
	$(CONTAINER_RUNTIME) build --platform linux/amd64 -t haproxy-rpm-builder7:${VERSION}-${RELEASE} -f Dockerfile7 .
	$(CONTAINER_RUNTIME) build --platform linux/amd64 -t haproxy-rpm-builder8:${VERSION}-${RELEASE} -f Dockerfile8 .
	$(CONTAINER_RUNTIME) build --platform linux/amd64 -t haproxy-rpm-builder9:${VERSION}-${RELEASE} -f Dockerfile9 .
	$(CONTAINER_RUNTIME) build --platform linux/amd64 -t haproxy-rpm-builder-amzn2:${VERSION}-${RELEASE} -f Dockerfile-amzn2 .
	$(CONTAINER_RUNTIME) build --platform linux/amd64 -t haproxy-rpm-builder-amzn2023:${VERSION}-${RELEASE} -f Dockerfile-amzn2023 .

run-docker: build-docker
	mkdir -p RPMS
	chcon -Rt svirt_sandbox_file_t RPMS || true
	$(CONTAINER_RUNTIME) run --platform linux/amd64 --volume $(HOME)/RPMS:/RPMS --rm -e USE_PROMETHEUS=${USE_PROMETHEUS} -e RELEASE=${RELEASE} haproxy-rpm-builder7:${VERSION}-${RELEASE}
	$(CONTAINER_RUNTIME) run --platform linux/amd64 --volume $(HOME)/RPMS:/RPMS --rm -e USE_PROMETHEUS=${USE_PROMETHEUS} -e RELEASE=${RELEASE} haproxy-rpm-builder8:${VERSION}-${RELEASE}
	$(CONTAINER_RUNTIME) run --platform linux/amd64 --volume $(HOME)/RPMS:/RPMS --rm -e USE_PROMETHEUS=${USE_PROMETHEUS} -e RELEASE=${RELEASE} haproxy-rpm-builder9:${VERSION}-${RELEASE}
	$(CONTAINER_RUNTIME) run --platform linux/amd64 --volume $(HOME)/RPMS:/RPMS --rm -e USE_PROMETHEUS=${USE_PROMETHEUS} -e RELEASE=${RELEASE} haproxy-rpm-builder-amzn2:${VERSION}-${RELEASE}
	$(CONTAINER_RUNTIME) run --platform linux/amd64 --volume $(HOME)/RPMS:/RPMS --rm -e USE_PROMETHEUS=${USE_PROMETHEUS} -e RELEASE=${RELEASE} haproxy-rpm-builder-amzn2023:${VERSION}-${RELEASE}

build: $(build_stages)
	cp -r ./SPECS/* ./rpmbuild/SPECS/ || true
	cp -r ./SOURCES/* ./rpmbuild/SOURCES/ || true
	rpmbuild -ba SPECS/haproxy.spec \
	--define "mainversion ${MAINVERSION}" \
	--define "version ${VERSION}" \
	--define "release ${RELEASE}" \
	--define "_cpu ${CPU}" \
	--define "_extra_cflags ${EXTRA_CFLAGS}" \
	--define "_topdir %(pwd)/rpmbuild" \
	--define "_builddir %{_topdir}/BUILD" \
	--define "_buildroot %{_topdir}/BUILDROOT" \
	--define "_rpmdir %{_topdir}/RPMS" \
	--define "_srcrpmdir %{_topdir}/SRPMS" \
	--define "_use_lua ${USE_LUA}" \
	--define "_use_prometheus ${USE_PROMETHEUS}"