IMG ?= retro-k8s-poc/operator:pilot
CONTROLLER_GEN ?= controller-gen

.PHONY: generate manifests build test docker-build tidy

generate:
	$(CONTROLLER_GEN) object paths=./api/...

manifests:
	$(CONTROLLER_GEN) crd rbac:roleName=retrosession-operator paths=./... \
		output:crd:artifacts:config=../deploy/kubernetes/operator/crd/bases \
		output:rbac:artifacts:config=../deploy/kubernetes/operator/rbac

tidy:
	go mod tidy

build:
	go build -o bin/manager ./cmd/manager

test:
	go test ./...

docker-build:
	docker build -t $(IMG) .
