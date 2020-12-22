.PHONY: build build-local publish publish-source

build:
	rm -rf _site
	bundle exec jekyll build

build-local:
	bundle exec jekyll serve --force-polling

publish: build
	git --work-tree=_site add --all
	git --work-tree=_site commit -m "autogen: publish site"
	git --work-tree=_site push

publish-source:
	git push origin master:source
