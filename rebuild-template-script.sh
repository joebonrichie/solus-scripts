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

# Colours
ERROR='\033[0;31m' # red
INFO='\033[1;34m' # blue
PROGRESS='\033[0;32m' # green
NC='\033[0m' # No Color

# Count the number of packages
package_count() {
    echo -e ${PACKAGES} | wc -w
}

# Setup a build repo and a custom local repo for the rebuilds
setup() {
    if [ ! -z "$MAINPAK" ]; then
        echo -e "${INFO} > Setting up build repo...${NC}"
        mkdir -p ~/rebuilds/${MAINPAK}
        pushd ~/rebuilds/${MAINPAK}
        git clone ssh://vcs@dev.getsol.us:2222/source/common.git
        ln -sv common/Makefile.common .
        ln -sv common/Makefile.toplevel Makefile
        ln -sv common/Makefile.iso .
        echo -e "${INFO} > Setting up custom local repo...${NC}"
        sudo mkdir -p /var/lib/solbuild/local/${MAINPAK}
        sudo mkdir /etc/solbuild
        wget https://raw.githubusercontent.com/joebonrichie/solus-scripts/master/local-unstable-MAINPAK-x86_64.profile -P /tmp/
        sed -i "s/MAINPAK/${MAINPAK}/g" "/tmp/local-unstable-MAINPAK-x86_64.profile"
        sudo mv -v /tmp/local-unstable-MAINPAK-x86_64.profile /etc/solbuild/local-unstable-${MAINPAK}-x86_64.profile
        echo -e "${PROGRESS} > Done! ${NC}"
        set -e
        popd
    else
        echo -e "> ${ERROR} MAINPAK is empty, please edit the script and set it before continuing.${NC}"
    fi
}

# Concurrently clone repos
clone() {
    echo -e "${INFO} > Cloning packages...${NC}"
    pushd ~/rebuilds/${MAINPAK}
    (
    for i in ${PACKAGES}; do
        ((j=j%CONCURRENT_NETWORK_REQUESTS)); ((j++==0)) && wait
        make ${i}.clone &
    done
    )
    popd
}

# Run make bump on all packages
bump() {
    echo -e "${INFO} > Bumping the release number...${NC}"
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
    echo -e "${PROGRESS} > Done! ${NC}"
}

# Build all packages and move resulting eopkgs to local repo. Stop on error.
# Check if the eopkg exists before attempting to build and skip if it does.
build() {
    set -e
    # Do a naïve check that the package we are building against actually exists in the custom local repo before continuing.
    if ( ls /var/lib/solbuild/local/${MAINPAK} | grep -q ${MAINPAK}); then
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

            echo -e "${INFO} > Building package" ${var} "out of" $(package_count) "${NC}"
            # ! `ls *.eopkg`
            if [[ ! `ls /var/lib/solbuild/local/${MAINPAK}/${EOPKG}` ]]; then
                echo -e "Package doesn't exist, building:" ${i}
                sudo solbuild build package.yml -p local-unstable-${MAINPAK}-x86_64.profile;
                make abireport
                sudo mv *.eopkg /var/lib/solbuild/local/${MAINPAK}/
            fi;
        popd
        done
        popd
    else
        echo -e "${ERROR} > No package ${MAINPAK} was found in the repo. Remember to copy it to /var/lib/solbuild/local/${MAINPAK} before starting. ${NC}"
    fi
}

# Use tool of choice here to verify changes e.g. git diff, meld, etc.
verify() {
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))
        echo -e "Verifying package" ${var} "out of" $(package_count)
        git difftool --tool=gvimdiff3
      popd
    done
    popd
}

# Add and commit changes before publishing.
# TODO: add an excludes mechanism to allow a non-generic message for some packages.
commit() {
    echo -e "${INFO} > Committing changes for each package to git...${NC}"
    set -e
    pushd ~/rebuilds/${MAINPAK}
    for i in ${PACKAGES}
    do
      pushd ${i}
        var=$((var+1))
        echo -e "Committing package" ${var} "out of" $(package_count)
        make clean
        git add *
        git commit -m "Rebuild against ${MAINPAK}"
      popd
    done
    popd
    echo -e "${PROGRESS} > Done! ${NC}"
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
        echo -e "${INFO} > Publishing package" ${var} "out of" $(package_count) "${NC}"
        make publish
        
        # Figure out eopkg string.
        PKGNAME=`cat package.yml | grep ^name | awk '{ print $3 }' | tr -d "'"`
        RELEASE=`cat package.yml | grep ^release | awk '{ print $3 }' | tr -d "'"`
        VERSION=`cat package.yml | grep ^version | awk '{ print $3 }' | tr -d "'"`
        EOPKG="${PKGNAME}-${VERSION}-${RELEASE}-1-x86_64.eopkg"

        # Take note: your unstable repo can be called anything.
        while [[ `cat /var/lib/eopkg/index/unstable/eopkg-index.xml | grep ${EOPKG} | wc -l` -lt 1 ]] ; do 
          echo -e "${i} not ready"
          sleep 30
          sudo eopkg ur
        done
        echo -e "${PROGRESS} Finished ${i} ${NC}"
      popd
    done
    popd
    echo -e "${PROGRESS} > Finished publishing packages! ${NC}"
}

NUKE() {
        read -p "This will nuke all of your work, if you are sure input NUKE my work to continue. " prompt
        if [[ $prompt = "NUKE my work" ]]; then
            echo -e "Removing rebuilds repo for ${MAINPAK}"
            rm -fr ~/rebuilds/${MAINPAK}
            echo -e "Removing custom local repo for ${MAINPAK}"
            sudo rm -frv /var/lib/solbuild/local/${MAINPAK}
            echo -e "Remove custom local repo configuration file"
            sudo rm -v /etc/solbuild/local-unstable-${MAINPAK}-x86_64.profile
            echo -e "${PROGRESS} > Nuked. ${NC}"
        else
            echo -e "${ERROR} Wrong input to continue, aborting. ${NC}"
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

        echo -e "Moving package" ${var} "out of" $(package_count) "to build repo"
        if [[ `ls /var/lib/solbuild/local/${MAINPAK}/${EOPKG}` ]]; then
          echo -e ${i}
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

        echo -e "Moving package" ${var} "out of" $(package_count) "to local repo"
        if [[ `ls *.eopkg` ]]; then
          echo -e ${i}
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
        echo -e "${INFO} > Cleaning package(s)" ${var} "out of" $(package_count) "${NC}"
        make clean
      popd
    done
    popd
    echo -e "${PROGRESS} > Finished cleaning packages(s)! ${NC}"
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
cat << EOF
   Rebuild template script for rebuilding packages on Solus.

   Please read and edit the script with the appriate parameters before starting.
   Generally only the MAINPAK and PACKAGES variables will need to be set where MAINPAK
   is the package you are rebuilding against and PACKAGES are the packages that need to
   be rebuilt against it. To run unattended passwordless sudo needs to be enabled. Use at your own risk.

   Usage: ./rebuild-package.sh {setup,clone,bump,build,verify,commit,publish,NUKE}

   Explaination of commands:

   setup   : Creates a build repo for the rebuilds in as well as a custom local repo to place the resulting
           : eopkgs in. A custom local repo is used to isolate the normal local repo from the ongoing rebuilds.
           : The custom repo configuration can be found in /etc/solbuild/ after running setup.
           : If desired the custom repo can be edited to isolate it from the local repo.
   clone   : Clones all the packages in PACKAGES to the build repo (make package.clone).
   bump    : Increments the release number in the package.yml file on all packages in the build repo (make bump)
   build   : Iteratively builds all packages in PACKAGES. If the package already exists in the local
           : repo it will skip to the next package. Passwordless sudo is recommended here so it can run unattended.
   verify  : Uses a git diff tool of choice to verify the rebuilds e.g. to verify abi_used_libs has changed in all packages.
   commit  : Git commit the changes with a generic commit message.
   publish : Iteratively runs makes publish to push the package to the build server,
           : waits for the package to be indexed into the repo before pushing the next.
           : You may wish to use autopush instead.

   NUKE    : This will nuke all of your work and cleanup any created files or directories.
           : This should only be done when all work has been indexed into the repo. Use with caution!"

EOF
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

echo -e "Rerun with -h to display help."
