bootstrap:
	bash bootstrap.sh $(ARGS)

up:
	docker compose up -d

down:
	docker compose down -v

logs:
	docker compose logs -f

listen:
	python listener.py

simulate:
	python simulator.py

install:
	pip install -r requirements.txt

query:
	python query.py $(ARGS)

validate:
	python validate.py
