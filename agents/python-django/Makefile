WORKLOAD := $(shell basename "$(CURDIR)")
SCRIPTS := ../../scripts/workloads

.PHONY: build publish deploy smoke run
.NOTPARALLEL:

build:
	./build.sh

publish:
	$(SCRIPTS)/publish.sh "$(WORKLOAD)"

deploy:
	$(SCRIPTS)/deploy.sh "$(WORKLOAD)"

smoke:
	$(SCRIPTS)/smoke.sh "$(WORKLOAD)"

run: build publish deploy smoke
