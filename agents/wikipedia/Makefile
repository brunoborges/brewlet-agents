.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help run observability application summarize dashboards telemetry

help:
	@echo 'After make up at the repository root:'
	@echo '  make run                    Deploy the telemetry stack, summarizer and frontend'
	@echo '  make summarize URL=...      Summarize a Wikipedia article (needs make auth at the root)'
	@echo '  make dashboards             Open the dashboards'
	@echo '  make telemetry              Check that the example reported telemetry'

run: observability application

observability:
	@./observability/deploy.sh

application:
	@$(MAKE) --no-print-directory -C wikipedia-summarizer run
	@$(MAKE) --no-print-directory -C wikipedia-frontend run

summarize:
	@./summarize.sh $(if $(filter frontend,$(VIA)),--frontend) "$$URL"

dashboards:
	@./observability/dashboards.sh $$DASHBOARDS

telemetry:
	@./observability/telemetry-check.sh
