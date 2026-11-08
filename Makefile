VARS ?= packer/example.pkrvars.hcl

.PHONY: test image maps clean

test:
	shellcheck src/sbin/*.sh install.sh packer/provision/*.sh tests/*.sh
	bash tests/test_pki.sh
	python3 -m pytest -q tests

image:
	cd packer && packer init . && packer build -var-file=$(abspath $(VARS)) .

# Convert the (patched) vendored greybox maps to CORE 9 XML for inspection.
maps:
	rm -rf build/greybox build/maps
	mkdir -p build/maps
	cp -r vendor/greybox build/greybox
	for p in patches/greybox/*.patch; do \
	  [ ! -e "$$p" ] || patch -d build/greybox -p1 -s < "$$p" || exit 1; \
	done
	for m in build/greybox/share/maps/*.imn; do \
	  python3 src/imn2xml.py "$$m" -o build/maps/$$(basename "$$m" .imn).xml || echo "skipped $$m"; \
	done

clean:
	rm -rf build
