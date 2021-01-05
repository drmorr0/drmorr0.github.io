.PHONY: build build-local publish publish-source

build:
	rm -rf _site
	bundle exec jekyll build

local:
	bundle exec jekyll serve --force-polling

publish: build
	git co master
	cp -r _site/* .
	git add --all
	git commit -m "autogen: publish site"
	git push origin master
	git co source
