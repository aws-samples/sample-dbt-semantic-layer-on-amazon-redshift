.PHONY: help deploy destroy test

help:
	@echo "Targets:"
	@echo "  make deploy   - provision the Redshift Serverless demo stack (scripts/deploy.sh)"
	@echo "  make test     - run the end-to-end dbt + MetricFlow check (scripts/e2e-test.sh)"
	@echo "  make destroy  - tear down the stack; prompts to re-run with --yes (scripts/destroy.sh)"

deploy:
	./scripts/deploy.sh

test:
	./scripts/e2e-test.sh

# No --yes here on purpose: keep the human confirmation gate intact.
destroy:
	./scripts/destroy.sh
