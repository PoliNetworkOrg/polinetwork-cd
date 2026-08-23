PYTHON ?= python

.PHONY: html verify publish

html:
	$(PYTHON) scripts/build_report.py

verify: html
	test -s migration-plan.html
	test "$$(rg -c '^## ' migration-plan.md)" = "2"
	! rg -n '^\s*- \[[ xX]\]\s' migration-plan.md
	! rg -n 'Avanzamento checklist|progress-count|progress-bar|task-marker' migration-plan.html
	! rg -n 'main-<(run_number|n)>|main-[0-9]+' migration-plan.md migration-plan.html
	! rg -n '<script|<form|<iframe|<embed|javascript:|\son[a-z]+=' migration-plan.html

publish: verify
	npx postplan upload ./migration-plan.html --description "Piano operativo migrazione PoliNetwork da AKS a K3s"
