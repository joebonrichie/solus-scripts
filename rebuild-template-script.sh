#!/bin/bash

# A script to automate package rebuilds for solus.
# Can be adapted to suit the needs for different packages.

# A lot of improvements could be made here but it works well enough
# and ideally the tooling and infrastructure will be updated in the
# future to handle someof the shortcomings so scripts like these won't be neccessary.

# Typically, you would build the MAINPAK as usual and place it in /var/lib/solbuild/local
# Then run ./rebuild.sh {setup,bump,build,verify,commit,publish} for a typical workflow.

# The package we are building against. Should be in local repo.
MAINPAK="foobar"

# Track any troublesome packages here to deal with them manually. 
MANUAL="dogshit catshit"

# The packages to rebuild, in the order they need to be rebuilt.
# Use eopkg info and eopkg-deps to get the rev deps of the main package
# and take care to order them properly as we currently do not have
# a reverse dependency graph in eopkg.
PACKAGES="foo bar xyz"

# Count the number of packages
package_count() {
    echo ${PACKAGES} | wc -w
}

# Setup a build repo and clone the packages to rebuild
setup() {
    mkdir -p ~/rebuilds/${MAINPAK}
    pushd ~/rebuilds/${MAINPAK}
    git clone ssh://vcs@dev.getsol.us:2222/source/common.git
    ln -sv common/Makefile.common .
    ln -sv common/Makefile.toplevel Makefile
    ln -sv common/Makefile.iso .
    set -e
    for i in ${PACKAGES}
      do
        git clone ssh://vcs@dev.getsol.us:2222/source/${i}.git
      done
    popd
}

# Run make bump on all packages
bump() {
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
      do
        pushd ${i}
          make bump
        popd
      done
    popd
}

# Build all packages and move resulting eopkgs to local repo. Stop on error.
# Check if the eopkg exists before attempting to build and skip if it does.
build() {
    set -e
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))

        # Figure out the eopkg string.
        PKGNAME=`cat package.yml | grep ^name | awk '{ print $3 }' | tr -d "'"`
        RELEASE=`cat package.yml | grep ^release | awk '{ print $3 }' | tr -d "'"`
        VERSION=`cat package.yml | grep ^version | awk '{ print $3 }' | tr -d "'"`
        EOPKG="${PKGNAME}-${VERSION}-${RELEASE}-1-x86_64.eopkg"

        echo "Building package" ${var} "out of" $(package_count)
        # ! `ls *.eopkg`
        if [[ ! `ls /var/lib/solbuild/local/${EOPKG}` ]]; then
          echo "Package doesn't exist, building:" ${i}
          make local
          sudo mv *.eopkg /var/lib/solbuild/local
        fi;
        popd
	done
	popd
}

# Use tool of choice here to verify changes e.g. git diff, meld, etc.
verify() {
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))
        echo "Verifying package" ${var} "out of" $(package_count) 
        git difftool --tool=gvimdiff3
      popd
    done
    popd
}

# Add and commit changes before publishing.
commit() {
    set -e
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))
        echo "Committing package" ${var} "out of" $(package_count) 
        make clean
        git add *
        git commit -m "Rebuild against foobar"
      popd
    done
    popd
}

# Publish package to the build server and wait for it to be indexed into the repo
# before publishing the next package. Lower or increase sleep time depending on the size
# of packages being built.
publish() {
    set -e
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))
        echo "Publishing package" ${var} "out of" $(package_count)
        make publish
        
        # Figure out eopkg string.
        PKGNAME=`cat package.yml | grep ^name | awk '{ print $3 }' | tr -d "'"`
        RELEASE=`cat package.yml | grep ^release | awk '{ print $3 }' | tr -d "'"`
        VERSION=`cat package.yml | grep ^version | awk '{ print $3 }' | tr -d "'"`
        EOPKG="${PKGNAME}-${VERSION}-${RELEASE}-1-x86_64.eopkg"
        sleep 20

        # Take note: your unstable repo can be called anything.
        while [[ `cat /var/lib/eopkg/index/unstable/eopkg-index.xml | grep ${EOPKG} | wc -l` -lt 1 ]] ; do 
          echo "${i} not ready"
          sleep 30
          sudo eopkg ur
        done
        echo "Finished ${i}"
      popd
    done
    popd
}

# Move tracked packages in the local repo to the build repo
# If patterns are used to create a completely different subpackage name
# e.g. gpgme provides a python-gpg subpackage, it won't be moved.
# So check the local repo after it has finished.
moveLocaltoRepo() {
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))

        # Figure out the eopkg string.
        PKGNAME=`cat package.yml | grep ^name | awk '{ print $3 }' | tr -d "'"`
        RELEASE=`cat package.yml | grep ^release | awk '{ print $3 }' | tr -d "'"`
        VERSION=`cat package.yml | grep ^version | awk '{ print $3 }' | tr -d "'"`
        EOPKG="${PKGNAME}-${VERSION}-${RELEASE}-1-x86_64.eopkg"

        echo "Moving package" ${var} "out of" $(package_count) "to build repo"
        if [[ `ls /var/lib/solbuild/local/${EOPKG}` ]]; then
          echo ${i}
          sudo mv /var/lib/solbuild/local/${PKGNAME}-*${VERSION}-${RELEASE}-1-x86_64.eopkg .
        fi;
      popd
    done
    popd
}

# Move packages from the build repo to the local repo
moveRepotoLocal() {
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))

        echo "Moving package" ${var} "out of" $(package_count) "to local repo"
        if [[ `ls *.eopkg` ]]; then
          echo ${i}
          sudo mv *.eopkg /var/lib/solbuild/local
        fi;
      popd
    done
    popd
}

# make clean doesn't work with just a subset of the repo cloned.
cleanLocal(){
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))
        echo "Cleaning package(s)" ${var} "out of" $(package_count)
        make clean
      popd
    done
    popd
}

# This little guy allows to call functions as arguments.
"$@"
