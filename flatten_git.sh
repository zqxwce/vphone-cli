#!/bin/bash

COMMITMSG="Flatten submodules"
FORCE=0
REMOVE=0

usage(){
  echo "$(basename $0) [-f] [-r] [-m <msg>] <branch>" >&2
  exit 1
}

while getopts ":fmr:" opt; do
  case $opt in
    f)
      FORCE=1
      ;;
    r)
      REMOVE=1
      ;;
    m)
      COMMITMSG=$OPTARG
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage
      ;;
    :)
      echo "-$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done
shift $(($OPTIND - 1))

BRANCH=$1
if [ -z "$BRANCH" ]; then
  usage
fi

UNCOMMITTED=`git submodule | grep -e "^[^ ]"`
if [ -n "$UNCOMMITTED" ]; then
  echo "Current branch has uncommitted submodule changes. Cannot continue." >&2
  exit 1
fi

if [ $FORCE -eq 1 ]; then
  git branch -D $BRANCH > /dev/null 2>&1
fi
git checkout --orphan $BRANCH || exit

modules=`git submodule | cut -d" " -f3`
for module in $modules
do
  git rm --cached $module
  mv $module/.git $module/.git.orig.$$
  echo git add $module
  git add $module
done
git rm .gitmodules
git commit -m "$COMMITMSG"
for module in $modules; do
  if [ $REMOVE -eq 1 ]; then
    echo rm -r $module/.git.orig.$$
    rm -r $module/.git.orig.$$
  else
    echo mv $module/.git.orig.$$ $module/.git
    mv $module/.git.orig.$$ $module/.git
  fi

done