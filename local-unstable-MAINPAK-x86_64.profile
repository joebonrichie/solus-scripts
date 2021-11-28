#
# local-unstable-x86_64 configuration
#
# Build Solus packages using the unstable repository image.
# This is the default profile for the Solus build server and developers.
#
# Do not make changes to this file. solbuild is implemented in a stateless
# fashion, and will load files in a layered mechanism. If you wish to edit
# this profile, copy to /etc/solbuild/.
#
# It is generally advisable to create a *new* profile name in /etc, because
# we will load /etc/ before /usr/share. Thus, profiles with the same name
# in /etc/ are loaded *first* and will override this profile.
#
# Of course, if that's what you intended to do, then by all means, do so.

image = "unstable-x86_64"

### REBUILDS ###
# Rename MAINPAK according to rebuild-template-script.sh
################

# If you have a local repo providing packages that exist in the main
# repository already, you should remove the repo, and re-add it *after*
# your local repository:
remove_repos = ['Solus']
add_repos = ['MAINPAK','Local','Solus']

# Local repo for MAINPAK rebuilds
# A local repo with automatic indexing
[repo.MAINPAK]
uri = "/var/lib/solbuild/local/MAINPAK"
local = true
autoindex = true

### REBUILDS ###
# The local repo can be removed to isolate the rebuilds from the local repo if desired
################
# A local repo with automatic indexing
[repo.Local]
uri = "/var/lib/solbuild/local"
local = true
autoindex = true

# Re-add the Solus unstable repo
[repo.Solus]
uri = "https://mirrors.rit.edu/solus/packages/unstable/eopkg-index.xml.xz"
