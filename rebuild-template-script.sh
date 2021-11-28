#!/bin/bash

# A script to automate package rebuilds for solus.
# Can be adapted to suit the needs for different packages.

# A lot of improvements could be made here but it works well enough
# and ideally the tooling and infrastructure will be updated in the
# future to handle someof the shortcomings so scripts like these won't be neccessary.

# See Help() for usage.

# The package we are building against. Should be in our custom local repo.
MAINPAK="foobar"

# The packages to rebuild, in the order they need to be rebuilt.
# Use eopkg info and eopkg-deps to get the rev deps of the main package
# and take care to order them properly as we currently do not have
# a proper reverse dependency graph in eopkg.
PACKAGES="foo bar xyz"

# Don't DOS the server
CONCURRENT_NETWORK_REQUESTS=8

# At what percentage of disk usage does delete-cache run automatically
DELETE_CACHE_THRESHOLD=80

# Track any troublesome packages here to deal with them manually.
MANUAL="dogshit catshit"

# Count the number of packages
package_count() {
    echo ${PACKAGES} | wc -w
}

# Setup a build repo and a custom local repo for the rebuilds
setup() {
    if [ ! -z "$MAINPAK" ]; then
        # Setup the build repo
        mkdir -p ~/rebuilds/${MAINPAK}
        pushd ~/rebuilds/${MAINPAK}
        git clone ssh://vcs@dev.getsol.us:2222/source/common.git
        ln -sv common/Makefile.common .
        ln -sv common/Makefile.toplevel Makefile
        ln -sv common/Makefile.iso .
        # Setup a custom local repo
        sudo mkdir -p /var/lib/solbuild/local/${MAINPAK}
        sudo mkdir /etc/solbuild
        wget https://raw.githubusercontent.com/joebonrichie/solus-scripts/master/local-unstable-MAINPAK-x86_64.profile -P /tmp/
        sudo mv -v /tmp/local-unstable-MAINPAK-x86_64.profile /etc/solbuild/local-unstable-${MAINPAK}-x86_64.profile
        set -e
        popd
    else
        echo "MAINPAK is empty, please edit the script and set it before continuing."
    fi
}

# Concurrently clone repos
clone() {
    pushd ~/rebuilds/${MAINPAK}
    (
    for i in ${PACKAGES}; do
        ((j=j%CONCURRENT_NETWORK_REQUESTS)); ((j++==0)) && wait
        git clone ssh://vcs@dev.getsol.us:2222/source/${i}.git &
    done
    )
    popd
}

# Run make bump on all packages
bump() {
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
      do
        pushd ${i}
          make bump
          # Backup for when pyyaml shits the bed with sources
          # perl -i -pe 's/(release    : )(\d+)$/$1.($2+1)/e' package.yml
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
        
        # See if we need to free up some disk space before continuing.
        $(checkDeleteCache)

        # Figure out the eopkg string.
        PKGNAME=`cat package.yml | grep ^name | awk '{ print $3 }' | tr -d "'"`
        RELEASE=`cat package.yml | grep ^release | awk '{ print $3 }' | tr -d "'"`
        VERSION=`cat package.yml | grep ^version | awk '{ print $3 }' | tr -d "'"`
        EOPKG="${PKGNAME}-${VERSION}-${RELEASE}-1-x86_64.eopkg"

        echo "Building package" ${var} "out of" $(package_count)
        # ! `ls *.eopkg`
        if [[ ! `ls /var/lib/solbuild/local/${MAINPAK}/${EOPKG}` ]]; then
          echo "Package doesn't exist, building:" ${i}
          sudo solbuild build package.yml -p local-unstable-${MAINPAK}-x86_64.profile;
          make abireport
          sudo mv *.eopkg /var/lib/solbuild/local/${MAINPAK}/
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
        git commit -m "Rebuild against ${MAINPAK}"
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

NUKE() {
        read -p "This will nuke all of your work, if you are sure input 'NUKE my work' to continue. " prompt
        if [[ $prompt = "NUKE my work" ]]; then
            echo "Removing rebuilds repo for ${MAINPAK}"
            rm -fr ~/rebuilds/${MAINPAK}
            echo "Removing custom local repo for ${MAINPAK}"
            sudo rm -frv /var/lib/solbuild/local/${MAINPAK}
            echo "Remove custom local repo configuration file"
            sudo rm -v /etc/solbuild/local-unstable-${MAINPAK}-x86_64.profile
            echo "Done."
        else
            echo "Wrong input to continue, aborting."
        fi
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
        if [[ `ls /var/lib/solbuild/local/${MAINPAK}/${EOPKG}` ]]; then
          echo ${i}
          sudo mv /var/lib/solbuild/local/${MAINPAK}/${PKGNAME}-*${VERSION}-${RELEASE}-1-x86_64.eopkg .
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
          sudo mv *.eopkg /var/lib/solbuild/local/${MAINPAK}/
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

# If disk usage of the root parition is over a threshold then run
# solbuild dc -a to free up disk space.
checkDeleteCache() {
    DISKUSAGE=`df -H / | awk '{ print $5 }' | cut -d'%' -f1 | sed 1d`
    if [ $DISKUSAGE -ge $DELETE_CACHE_THRESHOLD ]; then
        sudo solbuild dc -a
    fi
}

# Display Help
Help() {
   echo "Rebuild template script for rebuilding packages on Solus."
   echo
   echo "Please read and edit the script with the appriate parameters before starting."
   echo "Generally only the MAINPAK and PACKAGES variables will need to be set."
   echo "To run unattended passwordless sudo needed to be enabled. Use at your own risk."
   echo
   echo "Usage: ./rebuild-package.sh {setup,clone,bump,build,verify,commit,publish,NUKE}"
   echo
   echo "Explaination of commands:"
   echo
   echo "setup   : Creates a build repo as well as a custom local repo to build packages in"
   echo "clone   : Clones all the packages in PACKAGES to the build repo"
   echo "bump    : Increments the release number on all packages in the build repo"
   echo "build   : Iteratively builds all PACKAGES, if the package already exists in the local"
   echo "        : repo it will skip to the next package. Passwordless sudo is recommended here so it can run unattended."
   echo "verify  : Uses a git diff tool of choice to verify the rebuilds e.g. abi_used_libs"
   echo "commit  : Git commit the changes with a generic commit message"
   echo "publish : Iteratively runs makes publish to push the package to the build server,"
   echo "        : waits for the package to be indexed into the repo before pushing the next."
   echo "        : You may wish to use autopush instead."
   echo
   echo "NUKE    : This will nuke all of your work and cleanup any created files or directories."
   echo "        : This should only be done when all work has been indexed into the repo. Use with caution!"
}

while getopts ":h" option; do
   case $option in
      h) # display Help
         Help
         exit;;
   esac
done

# This little guy allows to call functions as arguments.
"$@"

echo "Rerun with -h to display help."
