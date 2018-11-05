export PATH := $(PWD)/bin:$(PATH)
AWS_IMAGES = aws-java aws-author aws-publish aws-dispatcher
DOCKER_IMAGES = docker-java docker-author docker-publish docker-dispatcher
VAR_FILES = $(sort $(wildcard vars/*.json))
VAR_PARAMS = $(foreach var_file,$(VAR_FILES),-var-file $(var_file))
all_var_files := $(VAR_FILES)
# version: version of machine images to be created
version ?= 1.0.0
# packer_aem_version: version of packer-aem to be packaged
packer_aem_version ?= 3.3.1
aem_helloworld_custom_image_provisioner_version = 0.9.0

package: stage/packer-aem-$(packer_aem_version).tar.gz

stage/packer-aem-$(packer_aem_version).tar.gz: stage
	tar \
	    --exclude='stage*' \
			--exclude='.bundle' \
			--exclude='bin' \
	    --exclude='.git*' \
	    --exclude='.tmp*' \
	    --exclude='.idea*' \
	    --exclude='.DS_Store*' \
	    --exclude='logs*' \
	    --exclude='*.retry' \
	    --exclude='*.iml' \
	    -czf \
		$@ .

ci: clean deps lint validate package

deps:
	gem install bundler
	bundle install --binstubs
	bundle exec r10k puppetfile install --verbose --moduledir modules
	pip install -r requirements.txt
	# this is just a hack for now to override the default rpm installed version of PyYAML
	pip install PyYAML>=3.12 --ignore-installed
	# only needed while using shinesolutions/puppet-aem fork
	# TODO: remove when switching back to bstopp/puppet-aem
	rm -rf modules/aem/.git

# copy local Puppet modules
# the repositories must be located on the same directory as packer-aem
deps-local: deps
	cd ../puppet-aem-resources && make clean deps lint
	cd ../puppet-aem-curator && make clean deps lint
	rm -rf modules/aem_resources/*
	rm -rf modules/aem_curator/*
	cp -R ../puppet-aem-resources/* modules/aem_resources/
	cp -R ../puppet-aem-curator/* modules/aem_curator/

deps-test:
	wget "https://github.com/shinesolutions/aem-helloworld-custom-image-provisioner/releases/download/${aem_helloworld_custom_image_provisioner_version}/aem-helloworld-custom-image-provisioner-${aem_helloworld_custom_image_provisioner_version}.tar.gz" \
	  -O stage/custom/aem-custom-image-provisioner.tar.gz

deps-test-local:
	cd ../aem-helloworld-custom-image-provisioner && make clean deps lint package
	rm -rf stage/custom/aem-custom-image-provisioner.tar.gz
	cp ../aem-helloworld-custom-image-provisioner/stage/*.tar.gz stage/custom/custom/aem-custom-image-provisioner.tar.gz

clean:
	rm -rf bin .bundle .tmp Puppetfile.lock Gemfile.lock .gems modules packer_cache stage logs/

init:
	chmod +x scripts/*.sh

stage: init
	mkdir -p stage/ stage/custom/ logs/

lint:
	bundle exec puppet-lint \
		--fail-on-warnings \
		--no-140chars-check \
		--no-autoloader_layout-check \
		--no-documentation-check \
		--no-only_variable_string-check \
		--no-selector_inside_resource-check \
		provisioners/puppet/manifests/*.pp \
		provisioners/puppet/modules/*/manifests/*.pp
	shellcheck $$(find provisioners scripts -name '*.sh')

define validate_packer_template
	packer validate \
		-syntax-only \
		$(VAR_PARAMS) \
		-var "component=null" \
		$(1)
endef

validate:
	puppet parser validate \
		provisioners/puppet/manifests/*.pp \
		provisioners/puppet/modules/*/manifests/*.pp
	$(call validate_packer_template,templates/aws/generic.json)
	$(call validate_packer_template,templates/aws/author-publish-dispatcher.json)
	$(call validate_packer_template,templates/docker/generic.json)

config: stage
	scripts/run-playbook.sh set-config "${config_path}"

ami-ids: stage
	scripts/run-playbook.sh create-stack-builder-config "${config_path}"

$(AWS_IMAGES): stage
	$(eval COMPONENT := $(shell echo $@ | sed -e 's/^aws-//g'))
	PACKER_LOG_PATH=logs/packer-$@.log \
		PACKER_LOG=1 \
		packer build \
		$(VAR_PARAMS) \
		-var-file=vars/components/$(COMPONENT).json \
		-var 'version=$(version)' \
		templates/aws/generic.json

aws-author-publish-dispatcher: stage
	PACKER_LOG_PATH=logs/packer-$@.log \
		PACKER_LOG=1 \
		packer build \
		$(VAR_PARAMS) \
		-var-file=vars/components/author-publish-dispatcher.json \
		-var 'version=$(version)' \
		templates/aws/author-publish-dispatcher.json

$(DOCKER_IMAGES): stage
	$(eval COMPONENT := $(shell echo $@ | sed -e 's/^docker-//g'))
	PACKER_LOG_PATH=logs/packer-$@.log \
		PACKER_LOG=1 \
		packer build \
		$(VAR_PARAMS) \
		-var-file=vars/components/$(COMPONENT).json \
		-var 'version=$(version)' \
		templates/docker/generic.json

var_files:
	@echo $(all_var_files)

merge_var_files:
	@jq -s 'reduce .[] as $$item ({}; . * $$item)' $(all_var_files)

define config_examples
  rm -rf stage/user-config/$(1)-$(2)-$(3)
	mkdir -p stage/user-config/$(1)-$(2)-$(3)
	cp examples/user-config/sandpit.yaml stage/user-config/$(1)-$(2)-$(3)/
	cp examples/user-config/platform-$(1).yaml stage/user-config/$(1)-$(2)-$(3)/
	cp examples/user-config/os-$(2).yaml stage/user-config/$(1)-$(2)-$(3)/
	cp examples/user-config/$(3).yaml stage/user-config/$(1)-$(2)-$(3)/
	scripts/run-playbook.sh set-config stage/user-config/$(1)-$(2)-$(3)/
endef

config-examples: stage

config-examples-all: config-examples-aws-rhel7-aem62 config-examples-aws-rhel7-aem63 config-examples-aws-rhel7-aem64 config-examples-aws-centos7-aem62 config-examples-aws-centos7-aem63 config-examples-aws-centos7-aem64 config-examples-aws-amazon-linux2-aem62 config-examples-aws-amazon-linux2-aem63 config-examples-aws-amazon-linux2-aem64 config-examples-docker-centos7-aem62 config-examples-docker-centos7-aem63

config-examples-aws-rhel7-aem62: stage
	$(call config_examples,aws,rhel7,aem62)

config-examples-aws-rhel7-aem63: stage
	$(call config_examples,aws,rhel7,aem63)

config-examples-aws-rhel7-aem64: stage
	$(call config_examples,aws,rhel7,aem64)

config-examples-aws-centos7-aem62: stage
	$(call config_examples,aws,centos7,aem62)

config-examples-aws-centos7-aem63: stage
	$(call config_examples,aws,centos7,aem63)

config-examples-aws-centos7-aem64: stage
	$(call config_examples,aws,centos7,aem64)

config-examples-aws-amazon-linux2-aem62: stage
	$(call config_examples,aws,amazon-linux2,aem62)

config-examples-aws-amazon-linux2-aem63: stage
	$(call config_examples,aws,amazon-linux2,aem63)

config-examples-aws-amazon-linux2-aem64: stage
	$(call config_examples,aws,amazon-linux2,aem64)

config-examples-docker-centos7-aem62: stage
	$(call config_examples,docker,centos7,aem62)

config-examples-docker-centos7-aem63: stage
	$(call config_examples,docker,centos7,aem63)

test-integration-local-aws-rhel7-aem62: config-examples-aws-rhel7-aem62 deps-local deps-test-local
	./test/integration/test-examples.sh "$(test_id)" aws rhel7 aem62

test-integration-aws-rhel7-aem62: config-examples-aws-rhel7-aem62 deps deps-test
	./test/integration/test-examples.sh "$(test_id)" aws rhel7 aem62

define ami_ids_examples
  make config-examples-$(1)
	make ami-ids config_path=stage/user-config/$(1)/
endef

ami-ids-examples: stage
	$(call ami_ids_examples,aws-rhel7-aem62)
	$(call ami_ids_examples,aws-rhel7-aem63)
	$(call ami_ids_examples,aws-rhel7-aem64)

# convenient target for creating certificate using OpenSSL
create-cert:
	mkdir -p stage/certs/
	openssl req \
	    -new \
	    -newkey rsa:4096 \
			-nodes \
	    -days 365 \
	    -x509 \
	    -subj "/C=AU/ST=Victoria/L=Melbourne/O=Sample Organisation/CN=*.example.com" \
	    -keyout stage/certs/aem.key \
	    -out stage/certs/aem.cert

.PHONY: init $(AMIS) amis-all ci clean config lint validate create-ami-ids-yaml var_files merge_var_files package create-cert
